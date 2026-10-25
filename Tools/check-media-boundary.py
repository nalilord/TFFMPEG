#!/usr/bin/env python3
"""Audit public media interfaces and application consumers, including dependencies."""
import argparse
from pathlib import Path
import re
import sys

from pascal_source import code_tokens, imports, tokens

ROOT = Path(__file__).resolve().parent.parent
RTL = {"system", "sysutils", "classes", "math", "types", "syncobjs", "cthreads", "diagnostics"}
NATIVE = re.compile(r"^(?:[PT]?AV[A-Z_]|[PT]Sws|[PT]Swr|av[a-z0-9]*_|swr_|sws_|FFTypes$)")


def allowed_rtl(name):
    return name.lower().removeprefix("system.") in RTL


def audit(root=ROOT, consumers=()):
    units = {path.stem.lower(): path for path in (root / "Source").glob("*.pas")}
    public = [path for name, path in units.items()
              if (name == "tffmpeg.media" or name.startswith("tffmpeg.media.")) and ".internal." not in name]
    problems = []
    visited = set()

    def check(path, interface_only):
        key = (path, interface_only)
        if key in visited:
            return
        visited.add(key)
        source = path.read_text(encoding="utf-8-sig")
        # Included source could hide uses clauses/types from this audit. Public
        # contracts are intentionally self-contained; reject rather than ignore it.
        audited_source = source
        if interface_only:
            code = code_tokens(source)
            start = next((t.start for t in code if t.value.lower() == "interface"), len(source))
            end = next((t.start for t in code if t.value.lower() == "implementation"), len(source))
            audited_source = source[start:end]
        for token in tokens(audited_source):
            if token.kind == "comment" and re.match(r"(?:\{|\(\*)\$\s*(?:i|include)\s", token.value, re.I):
                problems.append(f"{path}: source includes are forbidden in audited public contracts/consumers")
        for name in imports(source, interface_only):
            if allowed_rtl(name):
                continue
            lower = name.lower()
            if not (lower == "tffmpeg.media" or lower.startswith("tffmpeg.media.")) or ".internal." in lower:
                problems.append(f"{path}: forbidden public dependency {name}")
            elif lower not in units:
                problems.append(f"{path}: unresolved public dependency {name}")
            else:
                check(units[lower], True)
        code = code_tokens(source)
        if interface_only:
            start = next((i + 1 for i, t in enumerate(code) if t.value.lower() == "interface"), len(code))
            end = next((i for i in range(start, len(code)) if code[i].value.lower() == "implementation"), len(code))
            code = code[start:end]
        for token in code:
            if NATIVE.match(token.value):
                problems.append(f"{path}:{token.line}: native identifier {token.value}")

    for path in public:
        check(path, True)
    for path in consumers:
        check(path, False)
    if not public:
        problems.append("No public media units found")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("consumers", nargs="*", type=Path)
    args = parser.parse_args()
    consumers = list(args.consumers)
    consumers.extend(path for path in (ROOT / "Examples").glob("*.dpr") if path.name != "DecodeAudio.dpr")
    problems = audit(consumers=consumers)
    for problem in problems:
        print(problem, file=sys.stderr)
    if not problems:
        print("PASS: public media dependencies and high-level consumers")
    return bool(problems)


if __name__ == "__main__":
    sys.exit(main())
