"""Main application entry point."""

from contextlib import asynccontextmanager
from hmac import compare_digest
from typing import Optional

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .api.errors import register_error_handlers
from .api.assistant_routes import router as assistant_router
from .api.item_routes import router as item_router
from .api.import_export_routes import router as import_export_router
from .api.system import SERVICE_VERSION
from .api.system_routes import router as system_router
from .api.subscription_routes import collection_router, subscription_router
from .application import NotificationSchedulerPort
from .runtime import RuntimeServices
from .storage import SQLiteRepository
from config.loader import Settings, load_settings


def create_app(
    settings: Optional[Settings] = None,
    repository: Optional[SQLiteRepository] = None,
    notification_scheduler: Optional[NotificationSchedulerPort] = None,
) -> FastAPI:
    """Create and configure FastAPI application."""
    active_settings = settings or load_settings()
    runtime = RuntimeServices(
        active_settings,
        repository=repository,
        notification_scheduler=notification_scheduler,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        runtime.close()

    app = FastAPI(
        title=f"{active_settings.app.name} API",
        description="Local-first schedule, task, and candidate API",
        version=SERVICE_VERSION,
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=active_settings.server.cors_allowed_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def optional_bearer_auth(request, call_next):
        configured_token = active_settings.secrets.admin_token
        public_paths = {
            "/",
            "/docs",
            "/openapi.json",
            "/v1/health",
            "/v1/capabilities",
        }
        if (
            configured_token is None
            or request.method == "OPTIONS"
            or request.url.path in public_paths
        ):
            return await call_next(request)
        if not request.url.path.startswith("/v1/"):
            return await call_next(request)
        authorization = request.headers.get("Authorization", "")
        scheme, _, supplied = authorization.partition(" ")
        expected = configured_token.get_secret_value()
        if scheme.lower() != "bearer" or not supplied or not compare_digest(supplied, expected):
            return JSONResponse(
                status_code=401,
                content={
                    "error": {
                        "code": "authentication_required",
                        "message": "A valid Bearer token is required",
                        "details": {},
                    }
                },
            )
        return await call_next(request)

    app.include_router(system_router)
    app.include_router(item_router)
    app.include_router(assistant_router)
    app.include_router(import_export_router)
    app.include_router(collection_router)
    app.include_router(subscription_router)
    app.state.settings = active_settings
    app.state.runtime = runtime
    register_error_handlers(app)

    @app.get("/")
    async def root():
        return {
            "message": "EasyCalendar API",
            "version": SERVICE_VERSION,
            "docs": "/docs",
        }

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    server = app.state.settings.server
    uvicorn.run(
        "src.main:app",
        host=server.host,
        port=server.port,
        reload=server.debug,
    )
