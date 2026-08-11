import { describe, expect, it } from "vitest";

import { app } from "../src/app";
import type { Bindings } from "../src/types";

const env = {
  ADMIN_TOKEN: "test-admin-token-with-enough-entropy",
  APP_NAME: "EasyCalendar",
  INSTANCE_NAME: "test",
  TIMEZONE: "Asia/Shanghai",
  LOCALE: "zh-CN",
  CORS_ALLOWED_ORIGINS: "https://client.example.com",
  SYNC_ENABLED: "true",
  SYNC_PULL_LIMIT: "200",
} as Bindings;

describe("Worker system endpoints", () => {
  it("serves health without authentication", async () => {
    const response = await app.request("/v1/health", {}, env);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "ok",
      service: "easycalendar",
      version: "0.1.0",
      schema_version: 2,
    });
  });

  it("reports implemented and configured capabilities separately", async () => {
    const response = await app.request("/v1/capabilities", {}, env);
    const payload = await response.json<Record<string, unknown>>();

    expect(response.status).toBe(200);
    expect(payload).not.toHaveProperty("admin_token");
    expect(payload).toMatchObject({
      api_version: "v1",
      features: { sync: true },
      configured: { sync: true },
    });
  });
});

describe("Worker request boundary", () => {
  it("rejects a missing bearer token with the common envelope", async () => {
    const response = await app.request(
      "/v1/unknown",
      { headers: { "X-Request-Id": "req_test" } },
      env,
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({
      error: {
        code: "unauthorized",
        message: "Invalid bearer token",
        details: {},
        request_id: "req_test",
      },
    });
  });

  it("rejects an incorrect bearer token", async () => {
    const response = await app.request(
      "/v1/sync/pull",
      { headers: { Authorization: "Bearer incorrect-token" } },
      env,
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({
      error: { code: "unauthorized" },
    });
  });

  it("allows a valid bearer token to reach routing", async () => {
    const response = await app.request(
      "/v1/unknown",
      { headers: { Authorization: `Bearer ${env.ADMIN_TOKEN}` } },
      env,
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({
      error: { code: "not_found" },
    });
  });

  it("fails closed when the server secret is absent", async () => {
    const response = await app.request(
      "/v1/sync/pull",
      { headers: { Authorization: "Bearer any-value" } },
      { ...env, ADMIN_TOKEN: undefined },
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: { code: "service_unavailable" },
    });
  });

  it("answers CORS preflight only for configured origins", async () => {
    const accepted = await app.request(
      "/v1/sync/pull",
      { method: "OPTIONS", headers: { Origin: "https://client.example.com" } },
      env,
    );
    const rejected = await app.request(
      "/v1/sync/pull",
      { method: "OPTIONS", headers: { Origin: "https://other.example.com" } },
      env,
    );

    expect(accepted.status).toBe(204);
    expect(accepted.headers.get("Access-Control-Allow-Origin")).toBe(
      "https://client.example.com",
    );
    expect(rejected.status).toBe(403);
  });
});
