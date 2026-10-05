"""Serve signed updater fixtures, including a stable release behind a page of nightlies."""

import copy
import json
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


class ReleaseHandler(SimpleHTTPRequestHandler):
    """Ordinary files use the standard handler; the pagination fixture supplies Link headers."""

    def do_GET(self) -> None:
        request = urlsplit(self.path)
        if request.path != "/paginated.json":
            super().do_GET()
            return

        query = parse_qs(request.query)
        if query.get("per_page") != ["100"]:
            self.send_error(400, "The updater must request 100 releases per page")
            return

        release = json.loads(Path("releases.json").read_text())[1]
        if query.get("page", ["1"]) == ["1"]:
            releases = []
            for number in range(100):
                nightly = copy.deepcopy(release)
                nightly["tag_name"] = f"v1000.0.0-nightly.{number}"
                releases.append(nightly)
            assert isinstance(self.server, ThreadingHTTPServer)
            port = self.server.server_port
            next_page = f"http://127.0.0.1:{port}/paginated.json?per_page=100&page=2"
        else:
            release["tag_name"] = "v999.0.0"
            release["prerelease"] = False
            signature = release["assets"][1]
            signature["browser_download_url"] = (
                signature["browser_download_url"].rsplit("/", 1)[0] + "/verified.sig"
            )
            releases = [release]
            next_page = None

        body = json.dumps(releases).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if next_page:
            self.send_header("Link", f'<{next_page}>; rel="next"')
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    os.chdir(sys.argv[1])
    with ThreadingHTTPServer(("127.0.0.1", 0), ReleaseHandler) as server:
        print(f"Serving updater fixtures on port {server.server_port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
