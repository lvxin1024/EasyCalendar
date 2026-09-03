import { readFile } from "node:fs/promises";

import { convertV4MiniflareOptions, Miniflare } from "miniflare";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { app } from "../src/app";
import type { Bindings } from "../src/types";

const token = "test-admin-token-with-enough-entropy";
const timestamp = "2026-08-11T08:00:00.000Z";
let miniflare: Miniflare;
let database: D1Database;
let env: Bindings;

function collectionChange(changeId: string, version = 1) {
  const updatedAt = version === 1 ? timestamp : "2026-08-11T09:00:00.000Z";
  return {
    change_id: changeId,
    device_id: "macbook-01",
    entity_type: "collection",
    entity_id: "collection_local",
    operation: version === 1 ? "create" : "update",
    version,
    updated_at: updatedAt,
    payload: {
      id: "collection_local",
      name: version === 1 ? "My calendar" : "Updated calendar",
      kind: "local",
      color: "#2563EB",
      readonly: false,
      created_at: timestamp,
      updated_at: updatedAt,
      deleted_at: null,
      version,
    },
  };
}

function itemChange(
  changeId: string,
  options: {
    deviceId?: string;
    title?: string;
    version?: number;
    updatedAt?: string;
    operation?: "create" | "update" | "delete";
    deletedAt?: string | null;
  } = {},
) {
  const deviceId = options.deviceId ?? "macbook-01";
  const version = options.version ?? 1;
  const updatedAt = options.updatedAt ?? timestamp;
  const operation = options.operation ?? (version === 1 ? "create" : "update");
  return {
    change_id: changeId,
    device_id: deviceId,
    entity_type: "item",
    entity_id: "item_01",
    operation,
    version,
    updated_at: updatedAt,
    payload: {
      id: "item_01",
      collection_id: "collection_local",
      type: "task",
      title: options.title ?? "Project sync",
      timezone: "Asia/Shanghai",
      all_day: false,
      status: "todo",
      reminders: [],
      tags: [],
      source: "local",
      metadata: {},
      created_at: timestamp,
      updated_at: updatedAt,
      deleted_at: options.deletedAt ?? null,
      version,
    },
  };
}

function cyclePeriodChange(changeId: string, version = 1) {
  const updatedAt = version === 1 ? timestamp : "2026-08-11T09:00:00.000Z";
  return {
    change_id: changeId,
    device_id: "macbook-01",
    entity_type: "cycle_period",
    entity_id: "cycle_01",
    operation: version === 1 ? "create" : "update",
    version,
    updated_at: updatedAt,
    payload: {
      id: "cycle_01",
      start_date: "2026-08-01",
      end_date: "2026-08-05",
      excluded_from_prediction: false,
      context: null,
      created_at: timestamp,
      updated_at: updatedAt,
      deleted_at: null,
      version,
      daily_logs: [
        {
          date: "2026-08-01",
          bleeding_level: "medium",
          spotting: false,
          symptoms: ["cramps"],
          updated_at: updatedAt,
        },
      ],
    },
  };
}

function subscriptionChange(
  changeId: string,
  collectionId = "collection_local",
) {
  return {
    change_id: changeId,
    device_id: "macbook-01",
    entity_type: "subscription",
    entity_id: "subscription_01",
    operation: "create",
    version: 1,
    updated_at: timestamp,
    payload: {
      id: "subscription_01",
      collection_id: collectionId,
      title: "Team calendar",
      url: "https://calendar.example.com/team.ics",
      enabled: true,
      refresh_interval_minutes: 180,
      metadata: { tags: [] },
      created_at: timestamp,
      updated_at: timestamp,
      deleted_at: null,
      version: 1,
    },
  };
}

async function push(
  idempotencyKey: string,
  changes: unknown[],
  deviceId = "macbook-01",
) {
  return app.request(
    "/v1/sync/push",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify({ device_id: deviceId, changes }),
    },
    env,
  );
}

async function pull(cursor?: string, limit?: number) {
  const query = new URLSearchParams();
  if (cursor) query.set("cursor", cursor);
  if (limit) query.set("limit", String(limit));
  return app.request(
    `/v1/sync/pull?${query}`,
    { headers: { Authorization: `Bearer ${token}` } },
    env,
  );
}

async function applyMigration(sql: string) {
  const statements = sql
    .split(";")
    .map((statement) => statement.trim())
    .filter(Boolean)
    .map((statement) => database.prepare(statement));
  await database.batch(statements);
}

beforeAll(async () => {
  miniflare = new Miniflare(
    convertV4MiniflareOptions({
      modules: true,
      script: "export default { fetch() { return new Response('ok') } }",
      d1Databases: ["DB"],
    }),
  );
  database = (await miniflare.getD1Database("DB")) as D1Database;
  const migration1 = await readFile("migrations/0001_initial.sql", "utf8");
  const migration2 = await readFile("migrations/0002_sync_protocol.sql", "utf8");
  const migration3 = await readFile("migrations/0003_sync_conflicts.sql", "utf8");
  const migration4 = await readFile("migrations/0004_cycle_sync.sql", "utf8");
  await applyMigration(migration1);
  await applyMigration(migration2);
  await applyMigration(migration3);
  await applyMigration(migration4);
  env = {
    ADMIN_TOKEN: token,
    APP_NAME: "EasyCalendar",
    INSTANCE_NAME: "test",
    TIMEZONE: "Asia/Shanghai",
    LOCALE: "zh-CN",
    CORS_ALLOWED_ORIGINS: "https://client.example.com",
    SYNC_ENABLED: "true",
    SYNC_PULL_LIMIT: "2",
    DB: database,
  };
});

beforeEach(async () => {
  await database.exec(`
    DELETE FROM sync_requests;
    DELETE FROM applied_changes;
    DELETE FROM sync_conflicts;
    DELETE FROM sync_entity_heads;
    DELETE FROM change_log;
    DELETE FROM items;
    DELETE FROM cycle_periods;
    DELETE FROM cycle_settings;
    DELETE FROM subscriptions;
    DELETE FROM collections;
    DELETE FROM sqlite_sequence WHERE name = 'change_log';
    DELETE FROM sqlite_sequence WHERE name = 'sync_conflicts';
  `);
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("sync push", () => {
  it("orders dependent entities before applying a batch", async () => {
    const response = await push("push_subscription", [
      subscriptionChange("chg_subscription"),
      collectionChange("chg_collection"),
    ]);

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      accepted: ["chg_collection", "chg_subscription"],
      rejected: [],
    });
    expect(
      await database
        .prepare("SELECT collection_id FROM subscriptions WHERE id = ?")
        .bind("subscription_01")
        .first(),
    ).toMatchObject({ collection_id: "collection_local" });
  });

  it("reports a useful message for missing foreign-key dependencies", async () => {
    const response = await push("push_missing_collection", [
      subscriptionChange("chg_missing_collection", "collection_missing"),
    ]);

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      accepted: [],
      rejected: [
        {
          change_id: "chg_missing_collection",
          code: "constraint_violation",
          message: "Referenced collection does not exist",
        },
      ],
    });
  });

  it("stores cycle period aggregates and settings as sync entities", async () => {
    const response = await push("push_cycle", [
      cyclePeriodChange("chg_cycle"),
      {
        change_id: "chg_cycle_settings",
        device_id: "macbook-01",
        entity_type: "cycle_settings",
        entity_id: "singleton",
        operation: "update",
        version: 1,
        updated_at: timestamp,
        payload: {
          id: "singleton",
          enabled: true,
          forecast_horizon: 1,
          updated_at: timestamp,
          deleted_at: null,
          version: 1,
        },
      },
    ]);
    expect(response.status).toBe(200);
    const responsePayload = await response.json<{ accepted: string[] }>();
    expect(responsePayload.accepted).toEqual([
      "chg_cycle",
      "chg_cycle_settings",
    ]);
    expect(
      await database.prepare("SELECT json_extract(payload, '$.daily_logs[0].date') AS date FROM cycle_periods WHERE id = ?").bind("cycle_01").first(),
    ).toMatchObject({ date: "2026-08-01" });
    expect(await database.prepare("SELECT id FROM cycle_settings").first()).toMatchObject({ id: "singleton" });
  });

  it("applies a batch once and replays the same idempotent response", async () => {
    const changes = [collectionChange("chg_collection"), itemChange("chg_item")];
    const first = await push("push_01", changes);
    const firstPayload = await first.json();
    const replay = await push("push_01", changes);

    expect(first.status).toBe(200);
    expect(firstPayload).toEqual({
      accepted: ["chg_collection", "chg_item"],
      rejected: [],
      conflicts: [],
      server_cursor: "cur_2",
    });
    expect(await replay.json()).toEqual(firstPayload);
    expect(
      await database.prepare("SELECT COUNT(*) AS count FROM change_log").first(),
    ).toMatchObject({ count: 2 });
  });

  it("rejects reuse of a batch key or change id with different content", async () => {
    expect((await push("push_01", [collectionChange("chg_01")])).status).toBe(200);

    const batchConflict = await push("push_01", [collectionChange("chg_02")]);
    const changeConflict = await push("push_02", [collectionChange("chg_01", 2)]);

    expect(batchConflict.status).toBe(409);
    expect(await batchConflict.json()).toMatchObject({
      error: { code: "idempotency_conflict" },
    });
    expect(changeConflict.status).toBe(200);
    expect(await changeConflict.json()).toMatchObject({
      accepted: [],
      rejected: [{ change_id: "chg_01", code: "idempotency_conflict" }],
    });
  });

  it("validates complete envelopes before writing", async () => {
    const invalid = collectionChange("chg_invalid") as Record<string, unknown>;
    invalid.updated_at = "2026-08-11 08:00:00";
    const response = await push("push_invalid", [invalid]);

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({
      error: { code: "validation_error" },
    });
    expect(
      await database.prepare("SELECT COUNT(*) AS count FROM change_log").first(),
    ).toMatchObject({ count: 0 });
  });

  it("resolves concurrent device edits deterministically and preserves the loser", async () => {
    await push("push_collection", [collectionChange("chg_collection")]);
    await push("push_base", [itemChange("chg_base")]);
    const concurrentAt = "2026-08-11T10:00:00.000Z";
    const editA = itemChange("chg_edit_a", {
      deviceId: "device-a",
      title: "Edit A",
      version: 2,
      updatedAt: concurrentAt,
    });
    const editZ = itemChange("chg_edit_z", {
      deviceId: "device-z",
      title: "Edit Z",
      version: 2,
      updatedAt: concurrentAt,
    });

    await push("push_edit_a", [editA], "device-a");
    const response = await push("push_edit_z", [editZ], "device-z");
    const payload = await response.json<{
      conflicts: Array<{
        resolution: string;
        winner: { change_id: string };
        loser: { change_id: string };
      }>;
    }>();
    const canonical = await database
      .prepare("SELECT payload FROM items WHERE id = ?")
      .bind("item_01")
      .first<{ payload: string }>();

    expect(JSON.parse(canonical!.payload)).toMatchObject({ title: "Edit Z" });
    expect(payload.conflicts).toEqual([
      expect.objectContaining({
        resolution: "incoming_won",
        winner: expect.objectContaining({ change_id: "chg_edit_z" }),
        loser: expect.objectContaining({ change_id: "chg_edit_a" }),
      }),
    ]);

    const history = await app.request(
      "/v1/sync/conflicts",
      { headers: { Authorization: `Bearer ${token}` } },
      env,
    );
    expect(await history.json()).toMatchObject({
      conflicts: [
        {
          entity_id: "item_01",
          winner: { change_id: "chg_edit_z", payload: { title: "Edit Z" } },
          loser: { change_id: "chg_edit_a", payload: { title: "Edit A" } },
        },
      ],
    });
  });

  it("keeps the same winner when the losing edit arrives last", async () => {
    await push("push_collection", [collectionChange("chg_collection")]);
    await push("push_base", [itemChange("chg_base")]);
    const concurrentAt = "2026-08-11T10:00:00.000Z";
    const editZ = itemChange("chg_edit_z", {
      deviceId: "device-z",
      title: "Edit Z",
      version: 2,
      updatedAt: concurrentAt,
    });
    const editA = itemChange("chg_edit_a", {
      deviceId: "device-a",
      title: "Edit A",
      version: 2,
      updatedAt: concurrentAt,
    });

    await push("push_edit_z", [editZ], "device-z");
    const response = await push("push_edit_a", [editA], "device-a");
    const payload = await response.json<{
      conflicts: Array<{ resolution: string; winner: { change_id: string } }>;
    }>();
    const canonical = await database
      .prepare("SELECT payload FROM items WHERE id = ?")
      .bind("item_01")
      .first<{ payload: string }>();

    expect(JSON.parse(canonical!.payload)).toMatchObject({ title: "Edit Z" });
    expect(payload.conflicts).toEqual([
      expect.objectContaining({
        resolution: "stored_won",
        winner: expect.objectContaining({ change_id: "chg_edit_z" }),
      }),
    ]);
  });

  it("lets a winning delete tombstone beat a concurrent edit", async () => {
    await push("push_collection", [collectionChange("chg_collection")]);
    await push("push_base", [itemChange("chg_base")]);
    const concurrentAt = "2026-08-11T10:00:00.000Z";
    await push(
      "push_edit",
      [
        itemChange("chg_edit", {
          deviceId: "device-a",
          title: "Still active",
          version: 2,
          updatedAt: concurrentAt,
        }),
      ],
      "device-a",
    );
    const tombstone = itemChange("chg_z_delete", {
      deviceId: "device-z",
      title: "Deleted",
      version: 2,
      updatedAt: concurrentAt,
      operation: "delete",
      deletedAt: concurrentAt,
    });

    await push("push_delete", [tombstone], "device-z");
    const canonical = await database
      .prepare("SELECT deleted_at, payload FROM items WHERE id = ?")
      .bind("item_01")
      .first<{ deleted_at: string; payload: string }>();

    expect(canonical!.deleted_at).toBe(concurrentAt);
    expect(JSON.parse(canonical!.payload)).toMatchObject({
      deleted_at: concurrentAt,
    });
  });
});

describe("sync pull", () => {
  it("continues from an ordered cursor without losing changes", async () => {
    await push("push_01", [
      collectionChange("chg_01"),
      collectionChange("chg_02", 2),
    ]);

    const first = await pull(undefined, 1);
    const firstPayload = await first.json<{
      cursor: string;
      has_more: boolean;
      changes: Array<{ change_id: string }>;
    }>();
    const second = await pull(firstPayload.cursor, 1);
    const secondPayload = await second.json<{
      cursor: string;
      has_more: boolean;
      changes: Array<{ change_id: string }>;
    }>();

    expect(firstPayload).toMatchObject({
      cursor: "cur_1",
      has_more: true,
      changes: [{ change_id: "chg_01" }],
    });
    expect(secondPayload).toMatchObject({
      cursor: "cur_2",
      has_more: false,
      changes: [{ change_id: "chg_02" }],
    });
  });

  it("rejects invalid cursors", async () => {
    const response = await pull("not-a-cursor");

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({
      error: { code: "validation_error" },
    });
  });
});
