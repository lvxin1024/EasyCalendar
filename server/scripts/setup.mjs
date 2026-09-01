#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { parse as parseYaml } from "yaml";

const serverDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const generatedDirectory = resolve(serverDirectory, ".generated");
const generatedConfigPath = resolve(generatedDirectory, "wrangler.json");
export const workerSchemaVersion = 4;

function fail(message) {
  throw new Error(message);
}

function objectAt(value, path) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail(`${path} must be an object`);
  }
  return value;
}

function stringAt(value, path) {
  if (typeof value !== "string" || !value.trim()) {
    fail(`${path} must be a non-empty string`);
  }
  return value.trim();
}

function booleanAt(value, path) {
  if (typeof value !== "boolean") fail(`${path} must be a boolean`);
  return value;
}

function assertKnownKeys(value, allowed, path) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) fail(`Unknown configuration key: ${path}.${key}`);
  }
}

export function parseSecrets(content) {
  const secrets = {};
  for (const [index, rawLine] of content.split(/\r?\n/).entries()) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) fail(`Invalid secrets entry on line ${index + 1}`);
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    secrets[key] = value;
  }
  return secrets;
}

export function validateConfig(rawConfig, rawSecrets) {
  const config = objectAt(rawConfig, "config");
  const app = objectAt(config.app, "app");
  const server = objectAt(config.server, "server");
  const storage = objectAt(config.storage, "storage");
  const sync = objectAt(config.sync, "sync");
  const deployment = objectAt(config.deployment, "deployment");

  assertKnownKeys(
    config,
    [
      "app",
      "server",
      "storage",
      "sync",
      "subscriptions",
      "assistant",
      "notifications",
      "transfer",
      "widget",
      "deployment",
    ],
    "config",
  );
  assertKnownKeys(
    app,
    [
      "name",
      "instance_name",
      "timezone",
      "locale",
      "data_dir",
      "default_collection_id",
      "default_collection_name",
      "default_collection_color",
    ],
    "app",
  );
  assertKnownKeys(
    server,
    ["mode", "host", "port", "debug", "public_url", "cors_allowed_origins"],
    "server",
  );
  assertKnownKeys(storage, ["driver", "sqlite_path", "backup_dir"], "storage");
  assertKnownKeys(sync, ["enabled", "pull_limit", "retry_limit"], "sync");
  assertKnownKeys(
    deployment,
    ["provider", "auto_migrate", "auto_backup_before_migrate"],
    "deployment",
  );

  const instanceName = stringAt(app.instance_name, "app.instance_name");
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(instanceName)) {
    fail("app.instance_name must be a lowercase Cloudflare-compatible name");
  }
  if (server.mode !== "cloudflare") fail("server.mode must be cloudflare");
  if (storage.driver !== "d1") fail("storage.driver must be d1");
  if (deployment.provider !== "cloudflare") {
    fail("deployment.provider must be cloudflare");
  }
  if (!booleanAt(sync.enabled, "sync.enabled")) {
    fail("sync.enabled must be true for a Cloudflare sync server");
  }
  if (!Number.isInteger(sync.pull_limit) || sync.pull_limit < 1 || sync.pull_limit > 1000) {
    fail("sync.pull_limit must be an integer between 1 and 1000");
  }

  const publicUrl = stringAt(server.public_url, "server.public_url");
  let parsedUrl;
  try {
    parsedUrl = new URL(publicUrl);
  } catch {
    fail("server.public_url must be a valid URL");
  }
  if (parsedUrl.protocol !== "https:") {
    fail("server.public_url must use HTTPS for Cloudflare deployment");
  }
  if (parsedUrl.pathname !== "/" || parsedUrl.search || parsedUrl.hash) {
    fail("server.public_url must not contain a path, query, or fragment");
  }

  const origins = server.cors_allowed_origins;
  if (!Array.isArray(origins) || origins.length === 0) {
    fail("server.cors_allowed_origins must contain at least one origin");
  }
  for (const origin of origins) {
    const value = stringAt(origin, "server.cors_allowed_origins[]");
    if (value === "*") fail("server.cors_allowed_origins cannot contain *");
    try {
      const url = new URL(value);
      if (!url.origin || url.origin === "null" || url.pathname !== "/") {
        fail("server.cors_allowed_origins entries must be URL origins");
      }
    } catch {
      fail("server.cors_allowed_origins entries must be valid URL origins");
    }
  }

  const adminToken = rawSecrets.ADMIN_TOKEN || process.env.ADMIN_TOKEN || "";
  if (adminToken.length < 32) {
    fail("ADMIN_TOKEN must contain at least 32 characters");
  }

  return {
    appName: stringAt(app.name, "app.name"),
    instanceName,
    timezone: stringAt(app.timezone, "app.timezone"),
    locale: stringAt(app.locale, "app.locale"),
    publicUrl: publicUrl.replace(/\/$/, ""),
    corsAllowedOrigins: origins,
    syncPullLimit: sync.pull_limit,
    adminToken,
    workerName: `${instanceName}-server`,
    databaseName: `${instanceName}-db`,
  };
}

export function buildWranglerConfig(config, databaseId) {
  const publicHostname = new URL(config.publicUrl).hostname;
  const wrangler = {
    $schema: "../node_modules/wrangler/config-schema.json",
    name: config.workerName,
    main: "../src/index.ts",
    compatibility_date: "2026-08-11",
    d1_databases: [
      {
        binding: "DB",
        database_name: config.databaseName,
        database_id: databaseId,
        migrations_dir: "../migrations",
      },
    ],
    vars: {
      APP_NAME: config.appName,
      INSTANCE_NAME: config.instanceName,
      TIMEZONE: config.timezone,
      LOCALE: config.locale,
      CORS_ALLOWED_ORIGINS: config.corsAllowedOrigins.join(","),
      SYNC_ENABLED: "true",
      SYNC_PULL_LIMIT: String(config.syncPullLimit),
    },
  };
  if (publicHostname.endsWith(".workers.dev")) {
    wrangler.workers_dev = true;
  } else {
    wrangler.workers_dev = false;
    wrangler.routes = [{ pattern: publicHostname, custom_domain: true }];
  }
  return wrangler;
}

function runWrangler(args, options = {}) {
  const executable = resolve(serverDirectory, "node_modules/.bin/wrangler");
  if (!existsSync(executable)) {
    fail("Worker dependencies are missing; run ./scripts/setup.sh install first");
  }
  const result = spawnSync(executable, args, {
    cwd: serverDirectory,
    encoding: "utf8",
    input: options.input,
    stdio: options.capture ? "pipe" : ["pipe", "inherit", "inherit"],
  });
  if (result.error) throw result.error;
  if (result.status !== 0) fail(`wrangler ${args[0]} failed`);
  return result.stdout || "";
}

function listDatabases() {
  const output = runWrangler(["d1", "list", "--json"], { capture: true });
  const databases = JSON.parse(output);
  if (!Array.isArray(databases)) fail("Unexpected response from wrangler d1 list");
  return databases;
}

function findDatabase(config) {
  return listDatabases().find((database) => database.name === config.databaseName);
}

function writeGeneratedConfig(config, databaseId) {
  mkdirSync(generatedDirectory, { recursive: true });
  writeFileSync(
    generatedConfigPath,
    `${JSON.stringify(buildWranglerConfig(config, databaseId), null, 2)}\n`,
    { mode: 0o600 },
  );
}

function ensureDatabase(config) {
  let database = findDatabase(config);
  if (!database) {
    runWrangler(["d1", "create", config.databaseName]);
    database = findDatabase(config);
  }
  const databaseId = database?.uuid || database?.id;
  if (!databaseId) fail(`Could not resolve D1 database ${config.databaseName}`);
  writeGeneratedConfig(config, databaseId);
  return databaseId;
}

function migrate(config) {
  ensureDatabase(config);
  runWrangler([
    "d1",
    "migrations",
    "apply",
    "DB",
    "--remote",
    "--config",
    generatedConfigPath,
  ]);
}

function deploy(config) {
  ensureDatabase(config);
  runWrangler(["deploy", "--config", generatedConfigPath]);
  runWrangler(
    ["secret", "put", "ADMIN_TOKEN", "--config", generatedConfigPath],
    { input: `${config.adminToken}\n` },
  );
}

async function smokeTest(config) {
  const response = await fetch(`${config.publicUrl}/v1/health`);
  if (!response.ok) fail(`Health smoke test failed with HTTP ${response.status}`);
  const payload = await response.json();
  if (payload.status !== "ok" || payload.schema_version !== workerSchemaVersion) {
    fail("Health smoke test returned an incompatible response");
  }
}

function readInputs(configPath, secretsPath) {
  if (!existsSync(configPath)) fail(`Configuration file not found: ${configPath}`);
  if (!existsSync(secretsPath)) fail(`Secrets file not found: ${secretsPath}`);
  const rawConfig = parseYaml(readFileSync(configPath, "utf8"));
  const rawSecrets = parseSecrets(readFileSync(secretsPath, "utf8"));
  return validateConfig(rawConfig, rawSecrets);
}

function parseArguments(argv) {
  let command = "setup";
  let configPath = resolve("config/app.yaml");
  let secretsPath = process.env.EASYCALENDAR_SECRETS;
  const args = [...argv];
  if (args[0] && !args[0].startsWith("-")) command = args.shift();
  while (args.length) {
    const flag = args.shift();
    const value = args.shift();
    if (flag === "--config" && value) configPath = resolve(value);
    else if (flag === "--secrets" && value) secretsPath = resolve(value);
    else fail(`Unknown or incomplete argument: ${flag}`);
  }
  return {
    command,
    configPath,
    secretsPath: secretsPath ? resolve(secretsPath) : resolve(dirname(configPath), "secrets.env"),
  };
}

async function main() {
  const { command, configPath, secretsPath } = parseArguments(process.argv.slice(2));
  const config = readInputs(configPath, secretsPath);

  if (command === "validate") {
    console.log("Cloudflare configuration is valid.");
  } else if (command === "create") {
    ensureDatabase(config);
    console.log(`D1 database is ready: ${config.databaseName}`);
  } else if (command === "migrate") {
    migrate(config);
  } else if (command === "deploy") {
    deploy(config);
  } else if (command === "status") {
    const database = findDatabase(config);
    console.log(database ? `D1 database is ready: ${config.databaseName}` : "D1 database is missing.");
  } else if (command === "setup") {
    migrate(config);
    deploy(config);
    await smokeTest(config);
    console.log(`EasyCalendar is available at ${config.publicUrl}`);
  } else {
    fail(`Unknown setup command: ${command}`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`setup: ${error.message}`);
    process.exitCode = 1;
  });
}
