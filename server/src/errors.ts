import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";

import type { AppEnv } from "./types";

export interface ErrorDetails {
  [key: string]: unknown;
}

export function requestId(c: Context<AppEnv>): string {
  const existing = c.get("request_id");
  if (existing) return existing;

  const value = c.req.header("X-Request-Id") || `req_${crypto.randomUUID()}`;
  c.set("request_id", value);
  return value;
}

export function errorResponse(
  c: Context<AppEnv>,
  status: ContentfulStatusCode,
  code: string,
  message: string,
  details: ErrorDetails = {},
) {
  return c.json(
    {
      error: {
        code,
        message,
        details,
        request_id: requestId(c),
      },
    },
    status,
  );
}
