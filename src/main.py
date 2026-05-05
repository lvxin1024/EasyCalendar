"""Main application entry point."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .api.routes import router
from ..config.settings import API_CONFIG


def create_app() -> FastAPI:
    """Create and configure FastAPI application."""
    app = FastAPI(
        title="text2calendar API",
        description="API for parsing text to calendar events and syncing with multiple calendar providers",
        version="1.0.0",
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(router)

    @app.get("/")
    async def root():
        return {
            "message": "text2calendar API",
            "version": "1.0.0",
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
