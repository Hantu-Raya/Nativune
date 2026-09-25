"""Manual test aid for builds compiled with -p:UpdaterTestHooks=true; never shipped.
Release builds ignore NATIVUNE_TEST_RELEASE_METADATA_URL.
"""

import argparse
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
import json


METADATA_PATH = "/repos/Hantu-Raya/Nativune/releases/latest"
DIGEST = "sha256:0000000000000000000000000000000000000000000000000000000000000000"


def parse_port(value):
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("port must be an integer") from error
    if not 0 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 0 and 65535")
    return port


def release_json(tag):
    release = {
        "tag_name": tag,
        "draft": False,
        "prerelease": False,
        "assets": [
            {
                "name": "Nativune-Setup.exe",
                "state": "uploaded",
                "size": 1234,
                "browser_download_url": (
                    f"https://github.com/Hantu-Raya/Nativune/releases/download/{tag}/Nativune-Setup.exe"
                ),
                "digest": DIGEST,
            }
        ],
    }
    return (json.dumps(release, indent=2) + "\n").encode("utf-8")


class MetadataRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._handle_metadata_request()

    def do_HEAD(self):
        self._handle_metadata_request()

    def _handle_metadata_request(self):
        scenario = self.server.scenario
        if self.path != METADATA_PATH:
            status = HTTPStatus.NOT_FOUND
            body = b"Not Found\n"
            content_type = "text/plain; charset=utf-8"
        elif scenario == "error":
            status = HTTPStatus.INTERNAL_SERVER_ERROR
            body = b"Internal Server Error\n"
            content_type = "text/plain; charset=utf-8"
        elif scenario == "notfound":
            status = HTTPStatus.NOT_FOUND
            body = b"Not Found\n"
            content_type = "text/plain; charset=utf-8"
        else:
            tag = "v0.1.11" if scenario == "available" else "v0.1.10"
            status = HTTPStatus.OK
            body = release_json(tag)
            content_type = "application/vnd.github+json; charset=utf-8"
        self._send_response(status, body, content_type)

    def _send_response(self, status, body, content_type):
        method = self.command or "-"
        path = self.path or "-"
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        print(f"{timestamp} {method} {path} {int(status)}", flush=True)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
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
    parser.add_argument("--scenario", required=True, choices=("available", "none", "error", "notfound"))
    parser.add_argument("--port", type=parse_port, default=0, help="loopback port (default: choose an available port)")
    args = parser.parse_args()

    with MetadataHTTPServer(("127.0.0.1", args.port), MetadataRequestHandler) as server:
        server.scenario = args.scenario
        print(f"http://127.0.0.1:{server.server_port}{METADATA_PATH}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
