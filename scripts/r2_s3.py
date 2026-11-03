"""Cloudflare R2 over its S3 API, with the standard library only.

Signing (AWS Signature Version 4, region auto, path-style URLs) and one
request. What a caller may write, and whether it may replace an object, is the
caller's policy: images are immutable (mac-upload.py), catalogs are replaced in
place (catalog_release.py). No message here names the endpoint: its host names
the account.
"""
from __future__ import annotations

import hashlib
import hmac
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import BinaryIO

EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
S3_NAMESPACE = "{http://s3.amazonaws.com/doc/2006-03-01/}"
BUCKET = re.compile(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")


class R2Error(Exception):
    """A request that can't go ahead."""


def sigv4_headers(*, method: str, host: str, path: str, query: dict[str, str], headers: dict[str, str],
                  payload_sha256: str, access_key: str, secret_key: str, region: str, amz_date: str,
                  service: str = "s3") -> dict[str, str]:
    """AWS Signature Version 4 request headers, Authorization included.

    `path` is already URI-encoded, as sent.
    """
    def quote(value: str) -> str:
        return urllib.parse.quote(value, safe="-_.~")

    signed_headers = {key.lower(): " ".join(value.split()) for key, value in headers.items()}
    signed_headers |= {"host": host, "x-amz-content-sha256": payload_sha256, "x-amz-date": amz_date}
    names = ";".join(sorted(signed_headers))
    canonical = "\n".join([
        method,
        path,
        "&".join(f"{quote(key)}={quote(value)}" for key, value in sorted(query.items())),
        "".join(f"{key}:{signed_headers[key]}\n" for key in sorted(signed_headers)),
        names,
        payload_sha256,
    ])
    day = amz_date[:8]
    scope = f"{day}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = f"AWS4{secret_key}".encode()
    for part in (day, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    signed_headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
                                       f"SignedHeaders={names}, Signature={signature}")
    return signed_headers


def error_code(error: urllib.error.HTTPError) -> str:
    """The S3 error code in a refusal's body, or ''."""
    detail = error.read().decode(errors="replace")
    code = re.search(r"<Code>([^<]{1,100})</Code>", detail)
    return code.group(1) if code else ""


def refusal_text(action: str, error: urllib.error.HTTPError) -> str:
    code = error_code(error)
    return f"R2 refused to {action} ({error.code}{f' {code}' if code else ''})"


@dataclass(frozen=True)
class Endpoint:
    """An account's S3 endpoint and a bucket in it."""

    host: str
    bucket: str
    access_key: str
    secret_key: str

    @classmethod
    def parse(cls, bucket: str, endpoint: str, access_key: str, secret_key: str) -> Endpoint:
        if BUCKET.fullmatch(bucket) is None:
            raise R2Error(f"invalid R2 bucket name: {bucket}")
        if access_key == "" or secret_key == "":
            raise R2Error("no R2 credentials (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY)")
        parsed = urllib.parse.urlsplit(endpoint)
        if not (parsed.scheme == "https" and parsed.hostname and not parsed.query and not parsed.fragment
                and not parsed.username and parsed.port is None):
            raise R2Error("R2_ENDPOINT must be https://<account>.r2.cloudflarestorage.com")
        if parsed.path.strip("/") not in ("", bucket):
            raise R2Error("R2_ENDPOINT has a path other than the bucket's name; set it to the account's S3 endpoint")
        return cls(parsed.hostname, bucket, access_key, secret_key)

    def request(self, method: str, key: str, *, query: dict[str, str] | None = None,
                headers: dict[str, str] | None = None, body: BinaryIO | None = None, size: int = 0,
                payload_sha256: str = EMPTY_SHA256, timeout: float = 600):
        """One signed request for KEY ('' for the bucket). HTTP errors are raised
        as urllib's HTTPError; an unreachable endpoint as R2Error."""
        path = f"/{self.bucket}/" + urllib.parse.quote(key, safe="/-_.~")
        query = query or {}
        signed = sigv4_headers(method=method, host=self.host, path=path, query=query, headers=headers or {},
                               payload_sha256=payload_sha256, access_key=self.access_key,
                               secret_key=self.secret_key, region="auto",
                               amz_date=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
        url = f"https://{self.host}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(sorted(query.items()), quote_via=urllib.parse.quote, safe="-_.~")
        request = urllib.request.Request(url, data=body, method=method)
        for name, value in signed.items():
            if name != "host":
                request.add_unredirected_header(name.title(), value)
        if body is not None:
            request.add_unredirected_header("Content-Length", str(size))
        try:
            return urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, OSError) as error:
            reason = getattr(error, "reason", error)
            raise R2Error(f"could not reach R2 for {method} {key or '/'}: {type(reason).__name__}") from None
