export interface Bindings {
  ADMIN_TOKEN?: string;
  APP_NAME: string;
  INSTANCE_NAME: string;
  TIMEZONE: string;
  LOCALE: string;
  CORS_ALLOWED_ORIGINS: string;
  SYNC_ENABLED: string;
  SYNC_PULL_LIMIT: string;
  DB: D1Database;
}

export interface AppEnv {
  Bindings: Bindings;
  Variables: {
    request_id: string;
  };
}
