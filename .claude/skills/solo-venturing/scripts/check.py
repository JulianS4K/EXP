#!/usr/bin/env python3
import re
import sys
from datetime import date, datetime
from pathlib import Path

FILES = ["CLAUDE.md", "VENTURE.md", "RESEARCH.md", "LOG.md", "ERRORS.md"]
REQUIRED_VENTURE_HEADINGS = [
    "## One-liner", "## Target user", "## Problem", "## Kill criteria",
    "## Gates", "## Decisions",
]
LONG_FILE_LINES = 200
STALE_OPEN_DAYS = 14
LAST_STAGE = 10
STAGE_RE = re.compile(r"^Stage:\s*(\d+)\b", re.M)
GATE_GO_RE = re.compile(r"^\s*(?:[-*]\s*)?Gate\s+(\d+)\s*[—–-]+\s*Go\b", re.M)
DATE_HEADING_RE = re.compile(r"^## (\d{4}-\d{2}-\d{2})\b", re.M)
PLACEHOLDER_RE = re.compile(r"<(product|who|do what|pain|One segment)")


def main(argv):
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    errors, warnings = [], []

    if not (root / "VENTURE.md").exists():
        print(f"no venture in {root}: VENTURE.md missing. "
              "Run scripts/new_venture.sh to start one.")
        return 2

    texts = {}
    for name in FILES:
        p = root / name
        if not p.exists():
            errors.append(f"{name}: missing")
            continue
        texts[name] = p.read_text(encoding="utf-8", errors="replace")
        n = texts[name].count("\n") + 1
        if n > LONG_FILE_LINES:
            warnings.append(f"{name}: {n} lines, past {LONG_FILE_LINES}; compact "
                            "(references/venture-files.md)")

    venture = texts.get("VENTURE.md", "")
    m = STAGE_RE.search(venture)
    stage = int(m.group(1)) if m else None
    if stage is not None and not 1 <= stage <= LAST_STAGE:
        errors.append(f"VENTURE.md: 'Stage: {stage}' is outside 1-{LAST_STAGE}")
        stage = None
    elif stage is None:
        errors.append(f"VENTURE.md: no 'Stage: <1-{LAST_STAGE}> <phase>' line")
    for h in REQUIRED_VENTURE_HEADINGS:
        if h not in venture:
            errors.append(f"VENTURE.md: heading '{h}' missing")
    if stage and stage >= 2:
        if PLACEHOLDER_RE.search(venture):
            warnings.append("VENTURE.md: template placeholders left at stage "
                            f"{stage}; phase 1 output is incomplete")
        kill = venture.split("## Kill criteria", 1)[-1].split("\n## ", 1)[0]
        if not re.search(r"^\s*\d+\.\s+(?!<)\S", kill, re.M):
            errors.append("VENTURE.md: no kill criteria written, stage >= 2 "
                          "requires them")
        gates = venture.split("## Gates", 1)[-1].split("\n## ", 1)[0]
        passed = {int(n) for n in GATE_GO_RE.findall(gates)}
        missing = [str(n) for n in range(1, stage) if n not in passed]
        if missing:
            errors.append(f"VENTURE.md: stage {stage} without a recorded 'Gate "
                          f"{', '.join(missing)} — Go' line under ## Gates; run "
                          "the gate, or record the founder's override as the "
                          "evidence, before moving the Stage: line")

    log = texts.get("LOG.md", "")
    dates = DATE_HEADING_RE.findall(log)
    if not dates:
        errors.append("LOG.md: no '## YYYY-MM-DD' section")
    else:
        today = date.today()
        for section in re.split(r"(?m)^(?=## \d{4}-\d{2}-\d{2})", log):
            dm = DATE_HEADING_RE.match(section)
            if not dm:
                continue
            try:
                d = datetime.strptime(dm.group(1), "%Y-%m-%d").date()
            except ValueError:
                errors.append(f"LOG.md: bad date heading '{dm.group(1)}'")
                continue
            age = (today - d).days
            opens = re.findall(r"^\s*-\s*Open:\s*(.+)$", section, re.M)
            if age > STALE_OPEN_DAYS and opens:
                warnings.append(f"LOG.md: {len(opens)} Open: item(s) under "
                                f"{dm.group(1)} ({age} days old); close or carry forward")

    err = texts.get("ERRORS.md", "")
    entries = re.split(r"(?m)^## ", err)[1:]
    seen = {}
    for e in entries:
        title = e.splitlines()[0].strip()
        if title.startswith("<"):
            continue
        key = re.sub(r"\W+", " ", title.lower()).strip()
        if key in seen:
            warnings.append(f"ERRORS.md: duplicate rule '{title}'; merge and "
                            "sharpen instead of repeating")
        seen[key] = True
        if not re.search(r"^Rule:\s*\S", e, re.M):
            errors.append(f"ERRORS.md: entry '{title}' has no 'Rule:' line")
        if not re.search(r"^Seen:\s*\d{4}-\d{2}-\d{2}", e, re.M):
            warnings.append(f"ERRORS.md: entry '{title}' has no dated 'Seen:' line")

    claude = texts.get("CLAUDE.md", "")
    if "solo-venturing" not in claude:
        warnings.append("CLAUDE.md: does not mention the solo-venturing skill; "
                        "a cold session may not load it")

    for w in warnings:
        print(f"warn  {w}")
    for e in errors:
        print(f"error {e}")
    stage_txt = f"stage {stage}" if stage else "stage unknown"
    print(f"{root.name}: {stage_txt}, {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
