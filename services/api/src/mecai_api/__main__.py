"""Windows bundle entry point for the local MEC-AI API."""

import os

import uvicorn

from mecai_api.main import app


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=os.environ.get("MECAI_HOST", "127.0.0.1"),
        port=int(os.environ.get("MECAI_PORT", "8000")),
    )
