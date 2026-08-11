#!/usr/bin/env python3
"""Configuration-driven local entry point for EasyCalendar."""

from config.settings import API_CONFIG
from src.main import app

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "run:app",
        host=API_CONFIG["host"],
        port=API_CONFIG["port"],
        reload=API_CONFIG["debug"],
    )
