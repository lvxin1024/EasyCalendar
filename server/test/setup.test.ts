import { describe, expect, it } from "vitest";

import {
  buildWranglerConfig,
  parseSecrets,
  validateConfig,
} from "../scripts/setup.mjs";

const config = {
  app: {
    name: "EasyCalendar",
    instance_name: "my-easycalendar",
    timezone: "Asia/Shanghai",
    locale: "zh-CN",
  },
  server: {
    mode: "cloudflare",
    public_url: "https://calendar.example.com",
    cors_allowed_origins: ["https://client.example.com"],
  },
  storage: { driver: "d1" },
  sync: { enabled: true },
  deployment: { provider: "cloudflare" },
};
const secrets = { ADMIN_TOKEN: "a-secure-token-with-at-least-32-characters" };

describe("Cloudflare setup configuration", () => {
  it("validates the shared configuration and builds generated Wrangler input", () => {
    const validated = validateConfig(config, secrets);
    const wrangler = buildWranglerConfig(
      validated,
      "00000000-1111-2222-3333-444444444444",
    );

    expect(wrangler).toMatchObject({
      name: "my-easycalendar-server",
      d1_databases: [
        {
          binding: "DB",
          database_name: "my-easycalendar-db",
          database_id: "00000000-1111-2222-3333-444444444444",
        },
      ],
      vars: {
        TIMEZONE: "Asia/Shanghai",
        CORS_ALLOWED_ORIGINS: "https://client.example.com",
      },
      workers_dev: false,
      routes: [{ pattern: "calendar.example.com", custom_domain: true }],
    });
    expect(JSON.stringify(wrangler)).not.toContain(secrets.ADMIN_TOKEN);
  });

  it("rejects unsafe Cloudflare settings", () => {
    expect(() =>
      validateConfig(
        {
          ...config,
          server: {
            ...config.server,
            public_url: "http://calendar.example.com",
          },
        },
        secrets,
      ),
    ).toThrow("must use HTTPS");
    expect(() =>
      validateConfig(
        {
          ...config,
          server: { ...config.server, cors_allowed_origins: ["*"] },
        },
        secrets,
      ),
    ).toThrow("cannot contain *");
    expect(() => validateConfig(config, { ADMIN_TOKEN: "short" })).toThrow(
      "at least 32 characters",
    );
    expect(() =>
      validateConfig({ ...config, syncc: { enabled: true } }, secrets),
    ).toThrow("Unknown configuration key: config.syncc");
  });

  it("parses secret values without logging or serializing them", () => {
    expect(
      parseSecrets('ADMIN_TOKEN="secret value"\n# ignored\nAI_API_KEY=key\n'),
    ).toEqual({ ADMIN_TOKEN: "secret value", AI_API_KEY: "key" });
  });
});
