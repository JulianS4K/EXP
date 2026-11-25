#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

DEFAULT_WARN = 200_000
DEFAULT_STOP = 250_000
ACTIVE_WINDOW_SECONDS = 6 * 3600


def project_dirs(start):
    base = Path.home() / ".claude" / "projects"
    p = Path(start).resolve()
    while True:
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(p))
        d = base / slug
        if d.is_dir():
            yield d
        if p.parent == p:
            break
        p = p.parent


def latest_transcript(start):
    now = time.time()
    best = None
    for d in project_dirs(start):
        for f in d.glob("*.jsonl"):
            m = f.stat().st_mtime
            if now - m > ACTIVE_WINDOW_SECONDS:
                continue
            if best is None or m > best[0]:
                best = (m, f)
        if best:
            return best[1]
    return None


def last_usage(path):
    usage = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = obj.get("message")
            if isinstance(msg, dict) and isinstance(msg.get("usage"), dict):
                usage = msg["usage"]
    return usage


def main():
    ap = argparse.ArgumentParser(
        description="Report the context size of the current Claude Code session.")
    ap.add_argument("--warn", type=int, default=DEFAULT_WARN)
    ap.add_argument("--stop", type=int, default=DEFAULT_STOP)
    ap.add_argument("--dir", default=os.getcwd())
    args = ap.parse_args()

    path = latest_transcript(args.dir)
    if path is None:
        print(f"context: unknown (no active transcript under ~/.claude/projects for {args.dir})")
        return 3
    usage = last_usage(path)
    if usage is None:
        print(f"context: unknown (no usage records yet in {path.name})")
        return 3

    used = (usage.get("input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0))
    pct = 100 * used / args.stop
    if used >= args.stop:
        state, code = "STOP: write the venture files now and hand over", 2
    elif used >= args.warn:
        state, code = "WARN: finish the step, write the files, recommend /clear", 1
    else:
        state, code = "ok", 0
    print(f"context: {used:,} tokens ({pct:.0f}% of {args.stop:,} soft limit) — {state}")
    print(f"source: {path.name}")
    return code


if __name__ == "__main__":
    sys.exit(main())
