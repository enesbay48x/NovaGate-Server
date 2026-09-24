#!/usr/bin/env python3
"""
NovaGate Server Runner - Local Development

Usage:
    python run_server.py

Defaults:
    - Host: 0.0.0.0 (accepts localhost connections)
    - Port: 8000
    - DB: data/novagate.db

Environment variables:
    SERVER_HOST=0.0.0.0
    SERVER_PORT=8000
    SECRET_KEY=<required>
    DB_PATH=/app/data/novagate.db
"""

import os
import sys

# Ensure server directory is in path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Set defaults for local development if not already set
os.environ.setdefault("SERVER_HOST", "0.0.0.0")
os.environ.setdefault("SERVER_PORT", os.environ.get("PORT", "8000"))
os.environ.setdefault("SECRET_KEY", "dev-secret-key-change-in-production")
os.environ.setdefault("DB_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "novagate.db"))

import uvicorn

if __name__ == "__main__":
    from config import SERVER_HOST, SERVER_PORT

    print(f"Starting NovaGate server")
    print(f"  HTTP API: http://{SERVER_HOST}:{SERVER_PORT}")
    print(f"  WebSocket: ws://{SERVER_HOST}:{SERVER_PORT}/ws/game")
    print(f"  DB: {os.environ['DB_PATH']}")

    # Ensure data directory exists
    os.makedirs(os.path.dirname(os.environ["DB_PATH"]), exist_ok=True)

    uvicorn.run(
        "main:app",
        host=SERVER_HOST,
        port=SERVER_PORT,
        reload=False,
    )
