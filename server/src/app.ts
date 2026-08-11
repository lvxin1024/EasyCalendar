import { Hono } from "hono";

import { requireAdminToken } from "./auth";
import { errorResponse, requestId } from "./errors";
import { pullChanges, pushChanges } from "./sync";
import type { AppEnv } from "./types";

export const app = new Hono<AppEnv>();

app.use("*", async (c, next) => {
  const id = requestId(c);
  await next();
  c.header("X-Request-Id", id);
});

app.use("*", async (c, next) => {
  const origin = c.req.header("Origin");
  const allowed = (c.env.CORS_ALLOWED_ORIGINS || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);

  if (origin && allowed.includes(origin)) {
    c.header("Access-Control-Allow-Origin", origin);
    c.header("Vary", "Origin");
    c.header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS");
    c.header(
      "Access-Control-Allow-Headers",
      "Authorization, Content-Type, Idempotency-Key, X-Request-Id",
    );
    c.header("Access-Control-Expose-Headers", "X-Request-Id");
  }

  if (c.req.method === "OPTIONS") {
    return origin && allowed.includes(origin)
      ? c.body(null, 204)
      : errorResponse(c, 403, "origin_forbidden", "Origin is not allowed");
  }
  await next();
});

app.get("/v1/health", (c) =>
  c.json({
    status: "ok",
    service: "easycalendar",
    version: "0.1.0",
    schema_version: 2,
  }),
);

app.get("/v1/capabilities", (c) =>
  c.json({
    api_version: "v1",
    features: {
      parser: false,
      items: false,
      sync: true,
      ics_subscriptions: false,
      assistant: false,
      local_reminders: false,
      json_backup: false,
      ics_transfer: false,
      widget_snapshot: false,
    },
    configured: {
      sync: c.env.SYNC_ENABLED === "true",
      ics_subscriptions: false,
      assistant: false,
      local_reminders: false,
      widget_snapshot: false,
    },
    providers: {
      parser: [],
      ai: [],
      notification: [],
    },
    limits: {
      sync_push_batch: Number(c.env.SYNC_PULL_LIMIT || "200"),
      sync_pull_limit: Number(c.env.SYNC_PULL_LIMIT || "200"),
    },
  }),
);

app.use("/v1/*", requireAdminToken);

app.post("/v1/sync/push", pushChanges);
app.get("/v1/sync/pull", pullChanges);

app.notFound((c) =>
  errorResponse(c, 404, "not_found", "The requested resource does not exist"),
);

app.onError((_error, c) =>
  errorResponse(c, 500, "internal_error", "An unexpected error occurred"),
);
