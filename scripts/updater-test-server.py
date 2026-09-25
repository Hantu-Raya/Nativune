"""Manual test aid for builds compiled with -p:UpdaterTestHooks=true; never shipped.
Release builds ignore NATIVUNE_TEST_RELEASE_METADATA_URL.
"""

import argparse
from datetime import datetime, timezone
import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import time


METADATA_PATH = "/repos/Hantu-Raya/Nativune/releases/latest"
DOWNLOAD_PATH = "/download/Nativune-Setup.exe"
DIGEST = "sha256:0000000000000000000000000000000000000000000000000000000000000000"


def parse_port(value):
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("port must be an integer") from error
    if not 0 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 0 and 65535")
    return port


def parse_rate_kbps(value):
    try:
        rate = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("rate-kbps must be a positive integer") from error
    if rate <= 0:
        raise argparse.ArgumentTypeError("rate-kbps must be a positive integer")
    return rate


def release_json(tag, server):
    if server.setup_file is None:
        size = 1234
        download_url = (
            f"https://github.com/Hantu-Raya/Nativune/releases/download/{tag}/Nativune-Setup.exe"
        )
        digest = DIGEST
    else:
        size = server.setup_size
        download_url = f"http://127.0.0.1:{server.server_port}{DOWNLOAD_PATH}"
        digest = server.setup_digest
    release = {
        "tag_name": tag,
        "draft": False,
        "prerelease": False,
        "assets": [
            {
                "name": "Nativune-Setup.exe",
                "state": "uploaded",
                "size": size,
                "browser_download_url": download_url,
                "digest": digest,
            }
        ],
    }
    return (json.dumps(release, indent=2) + "\n").encode("utf-8")


class MetadataRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == DOWNLOAD_PATH:
            self._handle_download()
        else:
            self._handle_metadata_request()

    def do_HEAD(self):
        if self.path == DOWNLOAD_PATH:
            self._handle_download()
        else:
            self._handle_metadata_request()

    def _handle_metadata_request(self):
        scenario = self.server.scenario
        headers = {}
        if self.path != METADATA_PATH:
            status = HTTPStatus.NOT_FOUND
            body = b"Not Found\n"
            content_type = "text/plain; charset=utf-8"
        elif scenario == "error":
            status = HTTPStatus.INTERNAL_SERVER_ERROR
            body = b"Internal Server Error\n"
            content_type = "text/plain; charset=utf-8"
        elif scenario == "servererror":
            status = HTTPStatus.SERVICE_UNAVAILABLE
            body = b"Service Unavailable\n"
            content_type = "text/plain; charset=utf-8"
        elif scenario == "ratelimited":
            status = HTTPStatus.FORBIDDEN
            body = b"API rate limit exceeded\n"
            content_type = "text/plain; charset=utf-8"
            headers = {
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": str(int(datetime.now(timezone.utc).timestamp()) + 60),
            }
        elif scenario == "notfound":
            status = HTTPStatus.NOT_FOUND
            body = b"Not Found\n"
            content_type = "text/plain; charset=utf-8"
        else:
            tag = self.server.tag if scenario == "available" else "v0.1.10"
            status = HTTPStatus.OK
            body = release_json(tag, self.server)
            content_type = "application/vnd.github+json; charset=utf-8"
        self._send_response(status, body, content_type, headers)

    def _handle_download(self):
        setup_file = self.server.setup_file
        if self.server.scenario != "available" or setup_file is None:
            self._send_response(HTTPStatus.NOT_FOUND, b"Not Found\n", "text/plain; charset=utf-8")
            return
        try:
            source = setup_file.open("rb")
        except OSError:
            self._send_response(HTTPStatus.NOT_FOUND, b"Not Found\n", "text/plain; charset=utf-8")
            return

        method = self.command or "-"
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        print(f"{timestamp} {method} {DOWNLOAD_PATH} {int(HTTPStatus.OK)}", flush=True)
        with source:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(self.server.setup_size))
            self.end_headers()
            if method == "HEAD":
                return
            rate_bytes_per_second = (
                self.server.rate_kbps * 1000 / 8 if self.server.rate_kbps is not None else None
            )
            corrupt_offset = self.server.setup_size // 2 if self.server.corrupt else -1
            chunk_size = 64 * 1024
            if rate_bytes_per_second is not None:
                chunk_size = max(1, min(chunk_size, int(rate_bytes_per_second / 4)))
            started = time.monotonic()
            sent = 0
            try:
                while True:
                    chunk = source.read(chunk_size)
                    if not chunk:
                        break
                    if sent <= corrupt_offset < sent + len(chunk):
                        changed = bytearray(chunk)
                        changed[corrupt_offset - sent] ^= 1
                        chunk = changed
                    self.wfile.write(chunk)
                    sent += len(chunk)
                    if rate_bytes_per_second is not None:
                        delay = sent / rate_bytes_per_second - (time.monotonic() - started)
                        if delay > 0:
                            time.sleep(delay)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    def _send_response(self, status, body, content_type, headers=None):
        method = self.command or "-"
        path = (self.path or "-").partition("?")[0]
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        print(f"{timestamp} {method} {path} {int(status)}", flush=True)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        try:
            phrase = HTTPStatus(code).phrase
        except ValueError:
            phrase = "Error"
        body = f"{code} {phrase}\n".encode("utf-8")
        self._send_response(code, body, "text/plain; charset=utf-8")

    def log_message(self, format, *args):
        pass


class MetadataHTTPServer(HTTPServer):
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        pass


def main():
    parser = argparse.ArgumentParser(description="Serve local fake Nativune release metadata for manual updater tests.")
    parser.add_argument(
        "--scenario",
        required=True,
        choices=("available", "none", "error", "notfound", "ratelimited", "servererror"),
    )
    parser.add_argument("--port", type=parse_port, default=0, help="loopback port (default: choose an available port)")
    parser.add_argument("--setup-file", type=Path, help="serve this file as the available Setup asset")
    parser.add_argument("--rate-kbps", type=parse_rate_kbps, help="throttle the download in kilobits per second")
    parser.add_argument("--corrupt", action="store_true", help="flip one byte in the served Setup file")
    parser.add_argument("--tag", default="v0.1.11", help="release tag offered by the available scenario (match the served Setup version)")
    args = parser.parse_args()

    setup_file = args.setup_file
    setup_size = 0
    setup_digest = ""
    if setup_file is not None:
        if not setup_file.is_file():
            parser.error("--setup-file must name an existing file")
        setup_file = setup_file.resolve()
        setup_size = setup_file.stat().st_size
        if setup_size <= 0:
            parser.error("--setup-file must not be empty")
        digest = hashlib.sha256()
        with setup_file.open("rb") as source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        setup_digest = "sha256:" + digest.hexdigest()
    elif args.rate_kbps is not None or args.corrupt:
        parser.error("--rate-kbps and --corrupt require --setup-file")

    with MetadataHTTPServer(("127.0.0.1", args.port), MetadataRequestHandler) as server:
        server.scenario = args.scenario
        server.setup_file = setup_file
        server.setup_size = setup_size
        server.setup_digest = setup_digest
        server.rate_kbps = args.rate_kbps
        server.corrupt = args.corrupt
        server.tag = args.tag
        print(f"http://127.0.0.1:{server.server_port}{METADATA_PATH}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
