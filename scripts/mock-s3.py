#!/usr/bin/env python3
"""Minimal S3-compatible server for testing uploads locally.

Path-style buckets (/bucket/key), PUT/GET/HEAD/DELETE, and an independent
SigV4 check (header and presigned) so a wrong signature fails with 403
SignatureDoesNotMatch like real S3. Standard library only.

    scripts/mock-s3.py --port 9555 --access-key test --secret-key testsecret
"""
import argparse, hashlib, hmac, os, sys, urllib.parse
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OBJECTS = {}
ARGS = None


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def signature(secret, day, region, string_to_sign):
    k = sign(("AWS4" + secret).encode(), day)
    k = sign(k, region)
    k = sign(k, "s3")
    k = sign(k, "aws4_request")
    return hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()


def enc(s):
    return urllib.parse.quote(s, safe="-_.~")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        sys.stderr.write("mock-s3: " + fmt % a + "\n")

    def error(self, status, code, message):
        body = f"<Error><Code>{code}</Code><Message>{message}</Message></Error>".encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def canonical_query(self, pairs):
        items = sorted((enc(k), enc(v)) for k, v in pairs)
        return "&".join(f"{k}={v}" for k, v in items)

    def verify(self, body):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        q = dict(query)
        path = parsed.path  # already percent-encoded as sent
        if "X-Amz-Signature" in q:
            cred = q["X-Amz-Credential"].split("/")
            access, day, region = cred[0], cred[1], cred[2]
            amz_date = q["X-Amz-Date"]
            expires = int(q["X-Amz-Expires"])
            signed_time = datetime.strptime(amz_date, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            if datetime.now(timezone.utc) > signed_time + timedelta(seconds=expires):
                return "AccessDenied", "Request has expired"
            signed_headers = q["X-Amz-SignedHeaders"].split(";")
            given = q["X-Amz-Signature"]
            rest = [(k, v) for k, v in query if k != "X-Amz-Signature"]
            payload = "UNSIGNED-PAYLOAD"
        else:
            auth = self.headers.get("Authorization", "")
            if not auth.startswith("AWS4-HMAC-SHA256 "):
                return "AccessDenied", "Missing signature"
            fields = dict(part.strip().split("=", 1) for part in auth[len("AWS4-HMAC-SHA256 "):].split(","))
            cred = fields["Credential"].split("/")
            access, day, region = cred[0], cred[1], cred[2]
            signed_headers = fields["SignedHeaders"].split(";")
            given = fields["Signature"]
            amz_date = self.headers["x-amz-date"]
            rest = query
            payload = self.headers.get("x-amz-content-sha256", "")
            if payload != "UNSIGNED-PAYLOAD" and payload != hashlib.sha256(body).hexdigest():
                return "XAmzContentSHA256Mismatch", "Payload hash does not match"
        if access != ARGS.access_key:
            return "InvalidAccessKeyId", "Unknown access key"
        headers = "".join(f"{h}:{' '.join((self.headers.get(h) or '').split())}\n" for h in signed_headers)
        canonical = "\n".join([self.command, path or "/", self.canonical_query(rest), headers, ";".join(signed_headers), payload])
        scope = f"{day}/{region}/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        expected = signature(ARGS.secret_key, day, region, to_sign)
        if not hmac.compare_digest(expected, given):
            return "SignatureDoesNotMatch", "The request signature we calculated does not match"
        return None

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def key(self):
        return urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).lstrip("/")

    def do_PUT(self):
        data = self.body()
        failure = self.verify(data)
        if failure:
            return self.error(403, *failure)
        OBJECTS[self.key()] = (data, self.headers.get("Content-Type", "application/octet-stream"), self.headers.get("x-amz-acl"))
        self.send_response(200)
        self.send_header("ETag", '"' + hashlib.md5(data).hexdigest() + '"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self, head=False):
        failure = self.verify(b"")
        if failure:
            return self.error(403, *failure)
        if self.key() not in OBJECTS:
            return self.error(404, "NoSuchKey", "The specified key does not exist.")
        data, content_type, _ = OBJECTS[self.key()]
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if not head:
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET(head=True)

    def do_DELETE(self):
        failure = self.verify(b"")
        if failure:
            return self.error(403, *failure)
        OBJECTS.pop(self.key(), None)
        self.send_response(204)
        self.end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9555)
    parser.add_argument("--access-key", default="test")
    parser.add_argument("--secret-key", default="testsecret")
    ARGS = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print(f"mock-s3 listening on http://127.0.0.1:{ARGS.port}", flush=True)
    server.serve_forever()
