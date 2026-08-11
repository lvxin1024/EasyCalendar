import type { MiddlewareHandler } from "hono";

import { errorResponse } from "./errors";
import type { AppEnv } from "./types";

const encoder = new TextEncoder();

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
}

export async function constantTimeEqual(
  supplied: string,
  expected: string,
): Promise<boolean> {
  const [left, right] = await Promise.all([digest(supplied), digest(expected)]);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

export const requireAdminToken: MiddlewareHandler<AppEnv> = async (c, next) => {
  if (!c.env.ADMIN_TOKEN) {
    return errorResponse(
      c,
      503,
      "service_unavailable",
      "Server authentication is not configured",
    );
  }

  const authorization = c.req.header("Authorization") || "";
  const match = /^Bearer (\S+)$/.exec(authorization);
  const supplied = match?.[1] || "";
  if (!(await constantTimeEqual(supplied, c.env.ADMIN_TOKEN))) {
    return errorResponse(c, 401, "unauthorized", "Invalid bearer token");
  }

  await next();
};
