import hashlib
import http.server
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import threading


class DownloadHandler(http.server.BaseHTTPRequestHandler):
    requests = 0
    payload = b"complete dependency archive\n"

    def do_GET(self):
        type(self).requests += 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(self.payload)))
        self.end_headers()
        if self.requests <= 2:
            self.wfile.write(self.payload[:5])
            self.wfile.flush()
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                       struct.pack("ii", 1, 0))
            self.close_connection = True
        else:
            self.wfile.write(self.payload)

    def log_message(self, *_):
        pass


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "tools/build-dependencies.sh").read_text()
    functions = source[source.index("hash_file() {"):source.index("fetch_source openssl-")]
    server = http.server.HTTPServer(("127.0.0.1", 0), DownloadHandler)
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="greenovercast-download-test-") as temp:
            downloads = Path(temp) / "downloads"
            downloads.mkdir()
            fixture = Path(temp) / "fetch.sh"
            fixture.write_text("#!/bin/sh\nset -eu\n" + functions
                               + "\nDOWNLOADS=" + shlex.quote(str(downloads))
                               + '\nfetch_file "$@"\n')
            url = "http://127.0.0.1:%d/archive" % server.server_port
            digest = hashlib.sha256(DownloadHandler.payload).hexdigest()

            def fetch(name, expected):
                return subprocess.run(["sh", str(fixture), name, url, expected],
                                      capture_output=True, text=True, timeout=30)

            result = fetch("archive.tar", digest)
            assert result.returncode == 0, result.stderr
            assert DownloadHandler.requests == 3, DownloadHandler.requests
            assert (downloads / "archive.tar").read_bytes() == DownloadHandler.payload
            assert sorted(p.name for p in downloads.iterdir()) == ["archive.tar"]
            result = fetch("archive.tar", digest)
            assert result.returncode == 0, result.stderr
            assert DownloadHandler.requests == 3

            result = fetch("wrong-hash.tar", "0" * 64)
            assert result.returncode != 0
            assert "sha256 mismatch" in result.stderr
            assert sorted(p.name for p in downloads.iterdir()) == ["archive.tar"]

            (downloads / "archive.tar").write_bytes(b"preserve existing data")
            result = fetch("archive.tar", digest)
            assert result.returncode != 0
            assert (downloads / "archive.tar").read_bytes() == b"preserve existing data"
            assert DownloadHandler.requests == 4
    finally:
        server.shutdown()
        worker.join(timeout=5)
        server.server_close()
    print("Dependency download retries, checksum validation and atomic publication passed")


if __name__ == "__main__":
    main()
