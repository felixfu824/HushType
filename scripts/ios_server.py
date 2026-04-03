#!/usr/bin/env python3
"""
HushType iOS Server — proxy for mlx-audio with OpenCC s2twp conversion.

Proxies audio to the built-in mlx-audio server, then converts
Simplified → Traditional Chinese before returning to the iOS client.

Usage:
    python3 scripts/ios_server.py [--port 8100] [--backend-port 8000]

The mlx-audio backend is started automatically as a subprocess.

Dependencies:
    pip3 install "mlx-audio[stt,server]" fastapi uvicorn python-multipart httpx
    brew install opencc
"""

import argparse
import atexit
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

app = FastAPI(title="HushType iOS Server")

OPENCC_PATH = "/opt/homebrew/bin/opencc"
CJK_RANGE = re.compile(r"[\u4e00-\u9fff]")
BACKEND_URL = "http://127.0.0.1:{port}"
_backend_port = 8000
_backend_process = None


def has_cjk(text: str) -> bool:
    return bool(CJK_RANGE.search(text))


def convert_s2twp(text: str) -> str:
    if not has_cjk(text):
        return text
    if not Path(OPENCC_PATH).exists():
        return text
    try:
        result = subprocess.run(
            [OPENCC_PATH, "-c", "s2twp"],
            input=text, capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return text


def parse_ndjson_text(body: bytes) -> str:
    """Extract 'text' field from NDJSON response (last non-empty line)."""
    import json
    raw = body.decode("utf-8", errors="replace")
    for line in reversed(raw.strip().split("\n")):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            return obj.get("text", "")
        except Exception:
            continue
    return raw


@app.get("/")
def root():
    return {"status": "ok", "service": "HushType iOS Server", "opencc": Path(OPENCC_PATH).exists()}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.api_route("/v1/audio/transcriptions", methods=["POST"])
async def proxy_transcriptions(request: Request):
    """Proxy to mlx-audio backend, apply OpenCC, return clean JSON."""
    start = time.time()
    backend = BACKEND_URL.format(port=_backend_port)

    # Forward the raw request body to backend
    body = await request.body()
    headers = {
        "content-type": request.headers.get("content-type", ""),
    }

    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            f"{backend}/v1/audio/transcriptions",
            content=body,
            headers=headers,
        )

    if resp.status_code != 200:
        return Response(content=resp.content, status_code=resp.status_code,
                       media_type="application/json")

    # Parse the NDJSON response from mlx-audio
    text = parse_ndjson_text(resp.content)

    # Apply OpenCC s2twp
    converted = convert_s2twp(text)

    elapsed = time.time() - start
    print(f"[ios_server] {elapsed:.2f}s | {text}")
    if converted != text:
        print(f"[ios_server] s2twp → {converted}")

    return JSONResponse({"text": converted, "time": round(elapsed, 3)})


def start_backend(port: int):
    """Start mlx-audio server as a subprocess in the same process group."""
    global _backend_process
    print(f"[ios_server] Starting mlx-audio backend on 127.0.0.1:{port}...")
    _backend_process = subprocess.Popen(
        [sys.executable, "-m", "mlx_audio.server",
         "--host", "127.0.0.1", "--port", str(port), "--workers", "1"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        # Use same process group so parent kill also kills this child
        preexec_fn=None,  # inherit parent's process group
    )
    # Wait for backend to be ready
    for _ in range(30):
        time.sleep(1)
        try:
            r = httpx.get(f"http://127.0.0.1:{port}/", timeout=2)
            if r.status_code < 500:
                print(f"[ios_server] Backend ready on port {port}")
                return
        except Exception:
            pass
    print("[ios_server] WARNING: Backend may not be ready yet")


def stop_backend():
    global _backend_process
    if _backend_process:
        _backend_process.terminate()
        _backend_process.wait(timeout=5)
        _backend_process = None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="HushType iOS Server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000, help="Port for iOS clients")
    parser.add_argument("--backend-port", type=int, default=8199, help="Internal mlx-audio port")
    args = parser.parse_args()

    _backend_port = args.backend_port

    print(f"[ios_server] HushType iOS Server")
    print(f"[ios_server] Frontend: {args.host}:{args.port} (for iPhone)")
    print(f"[ios_server] Backend:  127.0.0.1:{args.backend_port} (mlx-audio)")
    print(f"[ios_server] OpenCC:   {'✓' if Path(OPENCC_PATH).exists() else '✗ not found'}")

    # Create a new process group so the parent (HushType app) can kill us + children
    os.setpgrp()

    # Ensure cleanup on any exit
    atexit.register(stop_backend)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        start_backend(args.backend_port)
        uvicorn.run(app, host=args.host, port=args.port, log_level="info")
    finally:
        stop_backend()
