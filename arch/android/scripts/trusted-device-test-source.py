#!/usr/bin/env python3
"""Serve an isolated GraphQL device index for Android runtime acceptance."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument(
        "--implementation",
        action="append",
        default=[],
        metavar="SPEC_ID=IMPLEMENTATION_ID",
    )
    return parser.parse_args()


def implementation_map(entries: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for entry in entries:
        spec_id, separator, implementation_id = entry.partition("=")
        if not separator or len(spec_id) != 43 or len(implementation_id) != 43:
            raise SystemExit(f"invalid --implementation mapping: {entry}")
        result[spec_id] = implementation_id
    return result


class Handler(BaseHTTPRequestHandler):
    implementations: dict[str, str]

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/health":
            self.reply(200, {"ok": True})
        else:
            self.reply(404, {"error": "not-found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/graphql":
            self.reply(404, {"error": "not-found"})
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            request = json.loads(self.rfile.read(length))
            spec_ids = request.get("variables", {}).get("specid", [])
            edges = [
                {"node": {"id": self.implementations[spec_id]}}
                for spec_id in spec_ids
                if spec_id in self.implementations
            ]
            self.reply(200, {"data": {"transactions": {"edges": edges}}})
        except (ValueError, json.JSONDecodeError, AttributeError) as error:
            self.reply(400, {"error": str(error)})

    def reply(self, status: int, body: dict[str, object]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format_string: str, *args: object) -> None:
        print(format_string % args, flush=True)


def main() -> None:
    args = parse_args()
    Handler.implementations = implementation_map(args.implementation)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
