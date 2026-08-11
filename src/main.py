"""Main application entry point."""

from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .api.routes import router
from .api.errors import register_error_handlers
from .api.assistant_routes import router as assistant_router
from .api.item_routes import router as item_router
from .api.import_export_routes import router as import_export_router
from .api.system import SERVICE_VERSION
from .api.system_routes import router as system_router
from .application import NotificationSchedulerPort
from .runtime import RuntimeServices
from .storage import SQLiteRepository
from config.loader import Settings
from config.settings import API_CONFIG, SETTINGS


def create_app(
    settings: Optional[Settings] = None,
    repository: Optional[SQLiteRepository] = None,
    notification_scheduler: Optional[NotificationSchedulerPort] = None,
) -> FastAPI:
    """Create and configure FastAPI application."""
    active_settings = settings or SETTINGS
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

    app.include_router(router)
    app.include_router(system_router)
    app.include_router(item_router)
    app.include_router(assistant_router)
    app.include_router(import_export_router)
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

    uvicorn.run(
        "src.main:app",
        host=API_CONFIG["host"],
        port=API_CONFIG["port"],
        reload=API_CONFIG["debug"],
    )
