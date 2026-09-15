"""Tiny localhost server that streams generated audio files (with HTTP Range) to the in-app player."""
from __future__ import annotations

import os
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_files: dict[str, str] = {}
_MIME = {".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".wav": "audio/wav"}


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # silence
        pass

    def do_GET(self):
        path = _files.get(self.path.strip("/"))
        if not path or not os.path.isfile(path):
            self.send_error(404); return
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start = int(a) if a else max(0, size - int(b))
            end = int(b) if (b and a) else size - 1
            end = min(end, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", _MIME.get(os.path.splitext(path)[1].lower(), "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 16, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)


class MediaServer:
    def __init__(self) -> None:
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self._srv.daemon_threads = True
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        self.port = self._srv.server_address[1]

    def url_for(self, path: str) -> str:
        token = secrets.token_urlsafe(12) + os.path.splitext(path)[1]
        _files[token] = path
        return f"http://127.0.0.1:{self.port}/{token}"
