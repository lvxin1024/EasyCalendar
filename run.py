#!/usr/bin/env python3
"""Configuration-driven local entry point for EasyCalendar."""

from src.main import app

if __name__ == "__main__":
    import uvicorn

    server = app.state.settings.server
    uvicorn.run(
        "run:app",
        host=server.host,
        port=server.port,
        reload=server.debug,
    )
