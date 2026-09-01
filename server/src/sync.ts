import type { Context } from "hono";

import { errorResponse } from "./errors";
import type { AppEnv } from "./types";

type EntityType =
  | "item"
  | "collection"
  | "subscription"
  | "cycle_period"
  | "cycle_settings";
type Operation = "create" | "update" | "delete";

interface SyncChange {
  change_id: string;
  device_id: string;
  entity_type: EntityType;
  entity_id: string;
  operation: Operation;
  version: number;
  updated_at: string;
  payload: Record<string, unknown>;
}

interface PushBody {
  device_id: string;
  changes: SyncChange[];
}

interface Rejection {
  change_id: string;
  code: string;
  message: string;
}

interface ConflictSummary {
  entity_type: EntityType;
  entity_id: string;
  resolution: "incoming_won" | "stored_won";
  winner: SyncChange;
  loser: SyncChange;
}

interface PushResponse {
  accepted: string[];
  rejected: Rejection[];
  conflicts: ConflictSummary[];
  server_cursor: string;
}

interface AppliedChangeRow {
  request_hash: string;
  result: string;
}

interface SyncRequestRow {
  request_hash: string;
  response_json: string;
}

interface ChangeLogRow {
  sequence: number;
  change_id: string;
  device_id: string;
  entity_type: EntityType;
  entity_id: string;
  operation: Operation;
  entity_version: number;
  changed_at: string;
  payload: string;
}

interface EntityHeadRow {
  change_id: string;
  device_id: string;
  entity_type: EntityType;
  entity_id: string;
  operation: Operation;
  entity_version: number;
  updated_at: string;
  payload: string;
}

interface ConflictRow {
  conflict_id: number;
  entity_type: EntityType;
  entity_id: string;
  winner: string;
  loser: string;
  recorded_at: string;
}

const idPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
const entityTypes = new Set<EntityType>([
  "item",
  "collection",
  "subscription",
  "cycle_period",
  "cycle_settings",
]);
const operations = new Set<Operation>(["create", "update", "delete"]);

function syncLimit(c: Context<AppEnv>): number {
  const configured = Number.parseInt(c.env.SYNC_PULL_LIMIT || "200", 10);
  return Number.isInteger(configured) && configured > 0 && configured <= 1000
    ? configured
    : 200;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validId(value: unknown): value is string {
  return typeof value === "string" && idPattern.test(value);
}

function validTimestamp(value: unknown): value is string {
  if (typeof value !== "string" || !/(Z|[+-]\d\d:\d\d)$/.test(value)) {
    return false;
  }
  return Number.isFinite(Date.parse(value));
}

function validateChange(value: unknown, deviceId: string): SyncChange {
  if (!isObject(value)) throw new Error("Each change must be an object");
  const allowed = new Set([
    "change_id",
    "device_id",
    "entity_type",
    "entity_id",
    "operation",
    "version",
    "updated_at",
    "payload",
  ]);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`Unknown change field: ${key}`);
  }
  if (!validId(value.change_id)) throw new Error("change_id is invalid");
  if (!validId(value.device_id) || value.device_id !== deviceId) {
    throw new Error("change device_id must match the batch device_id");
  }
  if (!entityTypes.has(value.entity_type as EntityType)) {
    throw new Error("entity_type is invalid");
  }
  if (!validId(value.entity_id)) throw new Error("entity_id is invalid");
  if (!operations.has(value.operation as Operation)) {
    throw new Error("operation is invalid");
  }
  if (!Number.isInteger(value.version) || (value.version as number) < 1) {
    throw new Error("version must be an integer of at least 1");
  }
  if (!validTimestamp(value.updated_at)) {
    throw new Error("updated_at must be an ISO 8601 timestamp with timezone");
  }
  if (!isObject(value.payload)) throw new Error("payload must be an object");
  if (value.payload.id !== value.entity_id) {
    throw new Error("payload.id must match entity_id");
  }
  if (value.payload.version !== value.version) {
    throw new Error("payload.version must match change version");
  }
  if (value.payload.updated_at !== value.updated_at) {
    throw new Error("payload.updated_at must match change updated_at");
  }
  if (value.operation === "delete" && !validTimestamp(value.payload.deleted_at)) {
    throw new Error("delete payload requires a deleted_at tombstone");
  }
  return value as unknown as SyncChange;
}

function validatePushBody(value: unknown, maximum: number): PushBody {
  if (!isObject(value)) throw new Error("Request body must be an object");
  for (const key of Object.keys(value)) {
    if (key !== "device_id" && key !== "changes") {
      throw new Error(`Unknown request field: ${key}`);
    }
  }
  if (!validId(value.device_id)) throw new Error("device_id is invalid");
  if (!Array.isArray(value.changes) || value.changes.length === 0) {
    throw new Error("changes must contain at least one change");
  }
  if (value.changes.length > maximum) {
    throw new Error(`changes cannot contain more than ${maximum} entries`);
  }
  const changes = value.changes.map((change) =>
    validateChange(change, value.device_id as string),
  );
  if (new Set(changes.map((change) => change.change_id)).size !== changes.length) {
    throw new Error("change_id values must be unique within a batch");
  }
  return { device_id: value.device_id, changes } as PushBody;
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item)).join(",")}]`;
  }
  if (isObject(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

async function hashJson(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonicalJson(value)),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function entityStatement(db: D1Database, change: SyncChange): D1PreparedStatement {
  const payloadJson = JSON.stringify(change.payload);
  const deletedAt =
    typeof change.payload.deleted_at === "string" ? change.payload.deleted_at : null;
  if (change.entity_type === "item") {
    const collectionId = change.payload.collection_id;
    const itemType = change.payload.type;
    if (!validId(collectionId) || !["event", "task", "note"].includes(String(itemType))) {
      throw new Error("Item payload requires collection_id and a valid type");
    }
    return db
      .prepare(
        `INSERT INTO items
          (id, collection_id, item_type, version, updated_at, deleted_at,
           payload, winner_change_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
          collection_id = excluded.collection_id,
          item_type = excluded.item_type,
          version = excluded.version,
          updated_at = excluded.updated_at,
          deleted_at = excluded.deleted_at,
          payload = excluded.payload,
          winner_change_id = excluded.winner_change_id
         WHERE julianday(excluded.updated_at) > julianday(items.updated_at)
            OR (
              julianday(excluded.updated_at) = julianday(items.updated_at)
              AND excluded.version > items.version
            )
            OR (
              julianday(excluded.updated_at) = julianday(items.updated_at)
              AND excluded.version = items.version
              AND excluded.winner_change_id > items.winner_change_id
            )`,
      )
      .bind(
        change.entity_id,
        collectionId,
        itemType,
        change.version,
        change.updated_at,
        deletedAt,
        payloadJson,
        change.change_id,
      );
  }
  if (change.entity_type === "subscription") {
    const collectionId = change.payload.collection_id;
    if (!validId(collectionId)) {
      throw new Error("Subscription payload requires collection_id");
    }
    return db
      .prepare(
        `INSERT INTO subscriptions
          (id, collection_id, version, updated_at, deleted_at, payload,
           winner_change_id)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
          collection_id = excluded.collection_id,
          version = excluded.version,
          updated_at = excluded.updated_at,
          deleted_at = excluded.deleted_at,
          payload = excluded.payload,
          winner_change_id = excluded.winner_change_id
         WHERE julianday(excluded.updated_at) > julianday(subscriptions.updated_at)
            OR (
              julianday(excluded.updated_at) = julianday(subscriptions.updated_at)
              AND excluded.version > subscriptions.version
            )
            OR (
              julianday(excluded.updated_at) = julianday(subscriptions.updated_at)
              AND excluded.version = subscriptions.version
              AND excluded.winner_change_id > subscriptions.winner_change_id
            )`,
      )
      .bind(
        change.entity_id,
        collectionId,
        change.version,
        change.updated_at,
        deletedAt,
        payloadJson,
        change.change_id,
      );
  }
  if (change.entity_type === "cycle_period") {
    if (!validId(change.payload.id) || typeof change.payload.start_date !== "string" ||
        (change.payload.end_date !== null && typeof change.payload.end_date !== "string") ||
        !validTimestamp(String(change.payload.created_at)) ||
        !validTimestamp(String(change.payload.updated_at)) ||
        !Array.isArray(change.payload.daily_logs)) {
      throw new Error("Cycle period payload is invalid");
    }
    return db
      .prepare(
        `INSERT INTO cycle_periods
          (id, version, updated_at, deleted_at, payload, winner_change_id)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
          version = excluded.version,
          updated_at = excluded.updated_at,
          deleted_at = excluded.deleted_at,
          payload = excluded.payload,
          winner_change_id = excluded.winner_change_id
         WHERE julianday(excluded.updated_at) > julianday(cycle_periods.updated_at)
            OR (julianday(excluded.updated_at) = julianday(cycle_periods.updated_at)
                AND excluded.version > cycle_periods.version)
            OR (julianday(excluded.updated_at) = julianday(cycle_periods.updated_at)
                AND excluded.version = cycle_periods.version
                AND excluded.winner_change_id > cycle_periods.winner_change_id)`,
      )
      .bind(change.entity_id, change.version, change.updated_at, deletedAt, payloadJson, change.change_id);
  }
  if (change.entity_type === "cycle_settings") {
    if (change.entity_id !== "singleton" || typeof change.payload.enabled !== "boolean" ||
        !Number.isInteger(change.payload.forecast_horizon) ||
        !validTimestamp(String(change.payload.updated_at))) {
      throw new Error("Cycle settings payload is invalid");
    }
    return db
      .prepare(
        `INSERT INTO cycle_settings
          (id, version, updated_at, deleted_at, payload, winner_change_id)
         VALUES ('singleton', ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
          version = excluded.version,
          updated_at = excluded.updated_at,
          deleted_at = excluded.deleted_at,
          payload = excluded.payload,
          winner_change_id = excluded.winner_change_id
         WHERE julianday(excluded.updated_at) > julianday(cycle_settings.updated_at)
            OR (julianday(excluded.updated_at) = julianday(cycle_settings.updated_at)
                AND excluded.version > cycle_settings.version)
            OR (julianday(excluded.updated_at) = julianday(cycle_settings.updated_at)
                AND excluded.version = cycle_settings.version
                AND excluded.winner_change_id > cycle_settings.winner_change_id)`,
      )
      .bind(change.version, change.updated_at, deletedAt, payloadJson, change.change_id);
  }
  return db
    .prepare(
      `INSERT INTO collections
        (id, version, updated_at, deleted_at, payload, winner_change_id)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
        version = excluded.version,
        updated_at = excluded.updated_at,
        deleted_at = excluded.deleted_at,
        payload = excluded.payload,
        winner_change_id = excluded.winner_change_id
       WHERE julianday(excluded.updated_at) > julianday(collections.updated_at)
          OR (
            julianday(excluded.updated_at) = julianday(collections.updated_at)
            AND excluded.version > collections.version
          )
          OR (
            julianday(excluded.updated_at) = julianday(collections.updated_at)
            AND excluded.version = collections.version
            AND excluded.winner_change_id > collections.winner_change_id
          )`,
    )
    .bind(
      change.entity_id,
      change.version,
      change.updated_at,
      deletedAt,
      payloadJson,
      change.change_id,
    );
}

function changeFromHead(row: EntityHeadRow): SyncChange {
  return {
    change_id: row.change_id,
    device_id: row.device_id,
    entity_type: row.entity_type,
    entity_id: row.entity_id,
    operation: row.operation,
    version: row.entity_version,
    updated_at: row.updated_at,
    payload: JSON.parse(row.payload) as Record<string, unknown>,
  };
}

function compareChanges(left: SyncChange, right: SyncChange): number {
  const timeDifference = Date.parse(left.updated_at) - Date.parse(right.updated_at);
  if (timeDifference !== 0) return timeDifference;
  if (left.version !== right.version) return left.version - right.version;
  if (left.change_id === right.change_id) return 0;
  return left.change_id > right.change_id ? 1 : -1;
}

function headStatement(db: D1Database, change: SyncChange): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO sync_entity_heads
        (entity_type, entity_id, change_id, device_id, operation,
         entity_version, updated_at, payload)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(entity_type, entity_id) DO UPDATE SET
        change_id = excluded.change_id,
        device_id = excluded.device_id,
        operation = excluded.operation,
        entity_version = excluded.entity_version,
        updated_at = excluded.updated_at,
        payload = excluded.payload
       WHERE julianday(excluded.updated_at) > julianday(sync_entity_heads.updated_at)
          OR (
            julianday(excluded.updated_at) = julianday(sync_entity_heads.updated_at)
            AND excluded.entity_version > sync_entity_heads.entity_version
          )
          OR (
            julianday(excluded.updated_at) = julianday(sync_entity_heads.updated_at)
            AND excluded.entity_version = sync_entity_heads.entity_version
            AND excluded.change_id > sync_entity_heads.change_id
          )`,
    )
    .bind(
      change.entity_type,
      change.entity_id,
      change.change_id,
      change.device_id,
      change.operation,
      change.version,
      change.updated_at,
      JSON.stringify(change.payload),
    );
}

async function applyChange(
  db: D1Database,
  change: SyncChange,
  hash: string,
): Promise<ConflictSummary | null> {
  const head = await db
    .prepare(
      `SELECT change_id, device_id, entity_type, entity_id, operation,
              entity_version, updated_at, payload
       FROM sync_entity_heads
       WHERE entity_type = ? AND entity_id = ?`,
    )
    .bind(change.entity_type, change.entity_id)
    .first<EntityHeadRow>();
  const stored = head ? changeFromHead(head) : null;
  const incomingWon = stored === null || compareChanges(change, stored) > 0;
  const isSuccessor =
    stored !== null && incomingWon && change.version === stored.version + 1;
  const hasConflict = stored !== null && !isSuccessor;
  const conflict: ConflictSummary | null = hasConflict
    ? {
        entity_type: change.entity_type,
        entity_id: change.entity_id,
        resolution: incomingWon ? "incoming_won" : "stored_won",
        winner: incomingWon ? change : stored,
        loser: incomingWon ? stored : change,
      }
    : null;
  const result = JSON.stringify({ status: "accepted", conflict });
  const statements: D1PreparedStatement[] = [];

  if (incomingWon) {
    statements.push(entityStatement(db, change), headStatement(db, change));
  }
  if (conflict) {
    statements.push(
      db
        .prepare(
          `INSERT OR IGNORE INTO sync_conflicts
            (entity_type, entity_id, winner_change_id, loser_change_id,
             winner, loser, recorded_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          conflict.entity_type,
          conflict.entity_id,
          conflict.winner.change_id,
          conflict.loser.change_id,
          JSON.stringify(conflict.winner),
          JSON.stringify(conflict.loser),
          new Date().toISOString(),
        ),
    );
  }
  statements.push(
    db
      .prepare(
        `INSERT INTO change_log
          (change_id, device_id, entity_type, entity_id, operation,
           entity_version, changed_at, payload)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        change.change_id,
        change.device_id,
        change.entity_type,
        change.entity_id,
        change.operation,
        change.version,
        change.updated_at,
        JSON.stringify(change.payload),
      ),
    db
      .prepare(
        `INSERT INTO applied_changes
          (change_id, request_hash, applied_at, result)
         VALUES (?, ?, ?, ?)`,
      )
      .bind(change.change_id, hash, new Date().toISOString(), result),
  );
  await db.batch(statements);
  return conflict;
}

async function serverCursor(db: D1Database): Promise<string> {
  const row = await db
    .prepare("SELECT COALESCE(MAX(sequence), 0) AS sequence FROM change_log")
    .first<{ sequence: number }>();
  return `cur_${row?.sequence ?? 0}`;
}

export async function pushChanges(c: Context<AppEnv>) {
  const idempotencyKey = c.req.header("Idempotency-Key");
  if (!idempotencyKey || !validId(idempotencyKey)) {
    return errorResponse(
      c,
      400,
      "validation_error",
      "A valid Idempotency-Key header is required",
    );
  }

  let body: PushBody;
  try {
    body = validatePushBody(await c.req.json(), syncLimit(c));
  } catch (error) {
    return errorResponse(
      c,
      400,
      "validation_error",
      error instanceof Error ? error.message : "Request body is invalid",
    );
  }

  const requestHash = await hashJson(body);
  const replay = await c.env.DB.prepare(
    "SELECT request_hash, response_json FROM sync_requests WHERE idempotency_key = ?",
  )
    .bind(idempotencyKey)
    .first<SyncRequestRow>();
  if (replay) {
    if (replay.request_hash !== requestHash) {
      return errorResponse(
        c,
        409,
        "idempotency_conflict",
        "Idempotency-Key was already used for a different request",
      );
    }
    return c.json(JSON.parse(replay.response_json) as PushResponse);
  }

  const accepted: string[] = [];
  const rejected: Rejection[] = [];
  const conflicts: ConflictSummary[] = [];
  for (const change of body.changes) {
    const changeHash = await hashJson(change);
    const prior = await c.env.DB.prepare(
      "SELECT request_hash, result FROM applied_changes WHERE change_id = ?",
    )
      .bind(change.change_id)
      .first<AppliedChangeRow>();
    if (prior) {
      if (prior.request_hash === changeHash) {
        accepted.push(change.change_id);
        const priorResult = JSON.parse(prior.result) as {
          conflict?: ConflictSummary | null;
        };
        if (priorResult.conflict) conflicts.push(priorResult.conflict);
      } else {
        rejected.push({
          change_id: change.change_id,
          code: "idempotency_conflict",
          message: "change_id was already used for different content",
        });
      }
      continue;
    }
    try {
      const conflict = await applyChange(c.env.DB, change, changeHash);
      accepted.push(change.change_id);
      if (conflict) conflicts.push(conflict);
    } catch (error) {
      rejected.push({
        change_id: change.change_id,
        code: "constraint_violation",
        message:
          error instanceof Error && error.message.startsWith("Item payload")
            ? error.message
            : error instanceof Error && error.message.startsWith("Subscription payload")
              ? error.message
              : "Change could not be applied",
      });
    }
  }

  const response: PushResponse = {
    accepted,
    rejected,
    conflicts,
    server_cursor: await serverCursor(c.env.DB),
  };
  await c.env.DB.prepare(
    `INSERT INTO sync_requests
      (idempotency_key, request_hash, response_json, created_at)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(
      idempotencyKey,
      requestHash,
      JSON.stringify(response),
      new Date().toISOString(),
    )
    .run();
  return c.json(response);
}

function parseCursor(value: string | undefined): number {
  if (!value) return 0;
  const match = /^cur_(0|[1-9]\d*)$/.exec(value);
  if (!match) throw new Error("cursor is invalid or unsupported");
  const sequence = Number(match[1]);
  if (!Number.isSafeInteger(sequence)) throw new Error("cursor is too large");
  return sequence;
}

export async function pullChanges(c: Context<AppEnv>) {
  let cursor: number;
  let limit: number;
  try {
    cursor = parseCursor(c.req.query("cursor"));
    const rawLimit = c.req.query("limit");
    limit = rawLimit ? Number(rawLimit) : syncLimit(c);
    if (!Number.isInteger(limit) || limit < 1 || limit > syncLimit(c)) {
      throw new Error(`limit must be between 1 and ${syncLimit(c)}`);
    }
  } catch (error) {
    return errorResponse(
      c,
      400,
      "validation_error",
      error instanceof Error ? error.message : "Pull query is invalid",
    );
  }

  const result = await c.env.DB.prepare(
    `SELECT sequence, change_id, device_id, entity_type, entity_id, operation,
            entity_version, changed_at, payload
     FROM change_log
     WHERE sequence > ?
     ORDER BY sequence
     LIMIT ?`,
  )
    .bind(cursor, limit + 1)
    .all<ChangeLogRow>();
  const rows = result.results;
  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  const nextCursor = page.length ? page[page.length - 1].sequence : cursor;

  return c.json({
    cursor: `cur_${nextCursor}`,
    has_more: hasMore,
    changes: page.map((row) => ({
      change_id: row.change_id,
      device_id: row.device_id,
      entity_type: row.entity_type,
      entity_id: row.entity_id,
      operation: row.operation,
      version: row.entity_version,
      updated_at: row.changed_at,
      payload: JSON.parse(row.payload) as Record<string, unknown>,
    })),
  });
}

export async function listConflicts(c: Context<AppEnv>) {
  const rawLimit = c.req.query("limit");
  const limit = rawLimit ? Number(rawLimit) : 100;
  if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
    return errorResponse(
      c,
      400,
      "validation_error",
      "limit must be between 1 and 500",
    );
  }
  const result = await c.env.DB.prepare(
    `SELECT conflict_id, entity_type, entity_id, winner, loser, recorded_at
     FROM sync_conflicts
     ORDER BY conflict_id DESC
     LIMIT ?`,
  )
    .bind(limit)
    .all<ConflictRow>();
  return c.json({
    conflicts: result.results.map((row) => ({
      conflict_id: row.conflict_id,
      entity_type: row.entity_type,
      entity_id: row.entity_id,
      winner: JSON.parse(row.winner) as SyncChange,
      loser: JSON.parse(row.loser) as SyncChange,
      recorded_at: row.recorded_at,
    })),
  });
}
