#!/usr/bin/env python3
"""Fail if a tracked file contains something that looks like a real secret.

Runs in CI (typecheck job) and locally: `python3 scripts/check-secrets.py`.
Scans `git ls-files` only, so ignored files (.env.local) are never read.

Test fixtures use obvious fakes (GOCSPX-client-secret, the jwt.io sample
token, a 4-byte PEM body); the patterns below require real-length values, and
JWTs are only flagged when their payload is a Supabase service-role or other
privileged token. If a new fixture trips this, make it obviously fake rather
than adding to ALLOW.
"""
import base64
import json
import re
import subprocess
import sys

PATTERNS = {
    "Stripe secret / restricted key": r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}",
    "Stripe webhook secret": r"\bwhsec_[A-Za-z0-9]{20,}",
    "Supabase secret key": r"\bsb_secret_[A-Za-z0-9_-]{20,}",
    "AWS access key": r"\bAKIA[0-9A-Z]{16}\b",
    "Google API key": r"\bAIza[0-9A-Za-z_-]{35}\b",
    "Google OAuth client secret": r"\bGOCSPX-[A-Za-z0-9_-]{24,}",
    "GitHub token": r"\bgh[pousr]_[A-Za-z0-9]{36,}",
    "Slack token": r"\bxox[baprs]-[A-Za-z0-9-]{20,}",
    "Anthropic / OpenAI key": r"\bsk-(?:ant-|proj-)[A-Za-z0-9_-]{30,}",
    "Resend key": r"\bre_[A-Za-z0-9]{8,}_[A-Za-z0-9]{16,}",
    "Private key": r"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\s*[A-Za-z0-9+/=\s]{120,}",
    "Postgres URL with password": r"postgres(?:ql)?://[^\s:@/]+:(?!password@|postgres@|\$)[^\s@/]{8,}@",
}
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.(eyJ[A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{20,}")

# path prefixes that are vendor reference material, never our credentials
SKIP_PREFIXES = ("node_modules/",)
ALLOW: set[tuple[str, str]] = set()


def jwt_is_privileged(payload_b64: str) -> bool:
    try:
        pad = "=" * (-len(payload_b64) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload_b64 + pad))
    except Exception:
        return False
    if not isinstance(claims, dict):
        return False
    return claims.get("role") in ("service_role", "supabase_admin") or claims.get("iss") == "supabase" and claims.get("role") != "anon"


def main() -> int:
    files = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.split(b"\0")
    found = []
    for raw in files:
        path = raw.decode(errors="replace")
        if not path or path.startswith(SKIP_PREFIXES):
            continue
        try:
            text = open(path, encoding="utf-8", errors="ignore").read()
        except (IsADirectoryError, FileNotFoundError):
            continue
        for name, pat in PATTERNS.items():
            for m in re.finditer(pat, text):
                if (path, name) not in ALLOW:
                    line = text.count("\n", 0, m.start()) + 1
                    found.append(f"{path}:{line}: {name} ({m.group(0)[:8]}…)")
        for m in JWT.finditer(text):
            if jwt_is_privileged(m.group(1)):
                line = text.count("\n", 0, m.start()) + 1
                found.append(f"{path}:{line}: privileged JWT ({m.group(0)[:8]}…)")
    if found:
        print("Possible secrets in tracked files (rotate them, then remove):")
        print("\n".join(found))
        return 1
    print(f"check-secrets: {len(files) - 1} tracked files, no secrets found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
