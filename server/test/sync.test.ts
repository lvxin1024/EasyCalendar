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

function itemChange(changeId: string) {
  return {
    change_id: changeId,
    device_id: "macbook-01",
    entity_type: "item",
    entity_id: "item_01",
    operation: "create",
    version: 1,
    updated_at: timestamp,
    payload: {
      id: "item_01",
      collection_id: "collection_local",
      type: "task",
      title: "Project sync",
      timezone: "Asia/Shanghai",
      all_day: false,
      status: "todo",
      reminders: [],
      tags: [],
      source: "local",
      metadata: {},
      created_at: timestamp,
      updated_at: timestamp,
      deleted_at: null,
      version: 1,
    },
  };
}

async function push(idempotencyKey: string, changes: unknown[]) {
  return app.request(
    "/v1/sync/push",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify({ device_id: "macbook-01", changes }),
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
  await applyMigration(migration1);
  await applyMigration(migration2);
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
    DELETE FROM change_log;
    DELETE FROM items;
    DELETE FROM subscriptions;
    DELETE FROM collections;
    DELETE FROM sqlite_sequence WHERE name = 'change_log';
  `);
});

afterAll(async () => {
  await miniflare.dispose();
});

describe("sync push", () => {
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
