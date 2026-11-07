#!/usr/bin/env python3
"""Throwaway OTLP/HTTP-JSON collector: appends every received body."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        raw = self.rfile.read(n)
        with open(OUT, 'a') as f:
            f.write(json.dumps({"path": self.path, "body": json.loads(raw)}) + "\n")
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{}')
    def log_message(self, *a):
        pass

open(OUT, 'w').close()
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
