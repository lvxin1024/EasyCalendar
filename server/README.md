# EasyCalendar Cloudflare server

`server/` contains the single-instance Cloudflare Worker and D1 foundation. T2.1
provides public system endpoints, Bearer authentication, CORS enforcement, the
common error envelope, initial D1 migrations, and the deployment entry point.
Push/pull synchronization is intentionally deferred to T2.2.

## Prerequisites

- Node.js 22
- A Cloudflare account authenticated with `npx wrangler login`
- A Cloudflare-hosted custom domain or the final `workers.dev` URL

Prepare `config/app.yaml` from the root example and set at least:

```yaml
server:
  mode: cloudflare
  public_url: https://calendar.example.com
  cors_allowed_origins:
    - https://client.example.com

storage:
  driver: d1

sync:
  enabled: true

deployment:
  provider: cloudflare
```

Set an `ADMIN_TOKEN` of at least 32 characters in the ignored
`config/secrets.env`. Then run:

```bash
./scripts/setup.sh install
./scripts/setup.sh validate --config config/app.yaml
./scripts/setup.sh --config config/app.yaml
```

The full setup creates or reuses the D1 database, applies migrations, generates
an ignored Wrangler configuration, deploys the Worker, stores `ADMIN_TOKEN` as a
Cloudflare secret, and checks `/v1/health`. It never prints the token.

Individual operations are available through `create`, `migrate`, `deploy`, and
`status`. The generated config lives in `server/.generated/`; users do not edit
or commit it.

## Local verification

```bash
cd server
npm ci
npm run check
```
