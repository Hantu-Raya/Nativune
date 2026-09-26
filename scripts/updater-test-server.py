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
import re
import time


METADATA_PATH = "/repos/Hantu-Raya/Nativune/releases/latest"
DOWNLOAD_PATH = "/download/Nativune-Setup.exe"
DIGEST = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
DOWNLOAD_PREFIX = "/download/"
DELTA_ASSETS = ("release-manifest.json", "Nativune-Setup.zip", "delta-update.json")
EXPLICIT_RANGE = re.compile(r"^bytes=([0-9]+)-([0-9]*)$")


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


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


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
    for name, (_, asset_size, asset_digest) in sorted(server.extra_assets.items()):
        release["assets"].append(
            {
                "name": name,
                "state": "uploaded",
                "size": asset_size,
                "browser_download_url": f"http://127.0.0.1:{server.server_port}{DOWNLOAD_PREFIX}{name}",
                "digest": asset_digest,
            }
        )
    return (json.dumps(release, indent=2) + "\n").encode("utf-8")


class MetadataRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def _dispatch(self):
        if self.path == DOWNLOAD_PATH:
            self._handle_download()
        elif self.path.startswith(DOWNLOAD_PREFIX) and self.path[len(DOWNLOAD_PREFIX):] in self.server.extra_assets:
            self._handle_extra_asset(self.path[len(DOWNLOAD_PREFIX):])
        else:
            self._handle_metadata_request()

    def _parse_range(self, size):
        """Returns None for a whole-file request, (start, end) for an explicit range, or an HTTP status."""
        value = self.headers.get("Range")
        if value is None:
            return None
        value = value.strip()
        if value.startswith("bytes=-"):
            # GitHub's asset CDN refuses suffix ranges; mimic it so clients never rely on them.
            return HTTPStatus.NOT_IMPLEMENTED
        match = EXPLICIT_RANGE.match(value)
        if match is None:
            return HTTPStatus.NOT_IMPLEMENTED
        start = int(match.group(1))
        end = int(match.group(2)) if match.group(2) else size - 1
        if start >= size or end < start:
            return HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE
        return (start, min(end, size - 1))

    def _handle_extra_asset(self, name):
        if self.server.scenario != "available":
            self._send_response(HTTPStatus.NOT_FOUND, b"Not Found\n", "text/plain; charset=utf-8")
            return
        path, size, _ = self.server.extra_assets[name]
        byte_range = self._parse_range(size)
        if isinstance(byte_range, HTTPStatus):
            headers = {"Content-Range": f"bytes */{size}"} if byte_range == HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE else {}
            self._send_response(byte_range, f"{int(byte_range)} {byte_range.phrase}\n".encode("utf-8"), "text/plain; charset=utf-8", headers)
            return
        start, end = (0, size - 1) if byte_range is None else byte_range
        try:
            with path.open("rb") as source:
                source.seek(start)
                body = source.read(end - start + 1)
        except OSError:
            self._send_response(HTTPStatus.NOT_FOUND, b"Not Found\n", "text/plain; charset=utf-8")
            return
        headers = {"Accept-Ranges": "bytes"}
        status = HTTPStatus.OK
        if byte_range is not None:
            status = HTTPStatus.PARTIAL_CONTENT
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        self._send_response(status, body, "application/octet-stream", headers)

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
        byte_range = self._parse_range(self.server.setup_size)
        if isinstance(byte_range, HTTPStatus):
            source.close()
            self._send_response(byte_range, f"{int(byte_range)} {byte_range.phrase}\n".encode("utf-8"), "text/plain; charset=utf-8")
            return
        start, end = (0, self.server.setup_size - 1) if byte_range is None else byte_range
        status = HTTPStatus.OK if byte_range is None else HTTPStatus.PARTIAL_CONTENT
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        print(f"{timestamp} {method} {DOWNLOAD_PATH} {int(status)}", flush=True)
        with source:
            source.seek(start)
            remaining = end - start + 1
            self.send_response(status)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(remaining))
            self.send_header("Accept-Ranges", "bytes")
            if byte_range is not None:
                self.send_header("Content-Range", f"bytes {start}-{end}/{self.server.setup_size}")
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
                while remaining > 0:
                    chunk = source.read(min(chunk_size, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    position = start + sent
                    if position <= corrupt_offset < position + len(chunk):
                        changed = bytearray(chunk)
                        changed[corrupt_offset - position] ^= 1
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
    parser.add_argument(
        "--delta-dir",
        type=Path,
        help="also serve release-manifest.json, Nativune-Setup.zip and delta-update.json from this folder (build-release.ps1 output)",
    )
    parser.add_argument("--tag", default="v0.1.11", help="release tag offered by the available scenario (match the served Setup version)")
    args = parser.parse_args()

    setup_file = args.setup_file
    setup_size = 0
    setup_digest = ""
    extra_assets = {}
    if args.delta_dir is not None:
        if setup_file is None:
            parser.error("--delta-dir requires --setup-file")
        for name in DELTA_ASSETS:
            path = (args.delta_dir / name).resolve()
            if not path.is_file() or path.stat().st_size <= 0:
                parser.error(f"--delta-dir must contain a non-empty {name}")
            extra_assets[name] = (path, path.stat().st_size, "sha256:" + file_sha256(path))
    if setup_file is not None:
        if not setup_file.is_file():
            parser.error("--setup-file must name an existing file")
        setup_file = setup_file.resolve()
        setup_size = setup_file.stat().st_size
        if setup_size <= 0:
            parser.error("--setup-file must not be empty")
        setup_digest = "sha256:" + file_sha256(setup_file)
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
        server.extra_assets = extra_assets
        print(f"http://127.0.0.1:{server.server_port}{METADATA_PATH}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
