#!/usr/bin/env python3
"""Check Pascal token casing, assignment spacing and local-declaration style without rewriting source."""
import argparse
from pathlib import Path
import re
import sys

from pascal_source import code_tokens, masked_code

ROOT = Path(__file__).resolve().parent.parent
UPPER = "and or not xor shl shr div mod in is as".split()
LOWER = "unit interface implementation uses type record class function procedure var const if then else begin end try finally except case of while do for repeat until property private protected public constructor destructor".split()
PASCAL = "String Char WideChar Integer Int64 UInt64 Boolean Byte Word Cardinal Single Double Pointer Array WriteLn ReadLn SizeOf Length SetLength Assigned Assert Inc Dec".split()
SPELLING = {word.lower(): word for word in [*(word.upper() for word in UPPER), *LOWER, *PASCAL]}


def check(source):
    problems = []
    for token in code_tokens(source):
        expected = SPELLING.get(token.value.lower())
        if expected is not None and token.value != expected:
            problems.append((token.line, f"use {expected}, found {token.value}"))
        if token.value == ":=" and (source[token.start - 1:token.start].isspace() or source[token.start + 2:token.start + 3].isspace()):
            problems.append((token.line, "no whitespace around :="))
    code = masked_code(source)
    for number, line in enumerate(code.splitlines(), 1):
        if re.search(r"\bfor\s+var\b|\bvar\s+\w+\s*:=", line, re.I):
            problems.append((number, "declare locals in the var section"))
        if re.search(r"\b(?:goto|label)\b", line, re.I):
            problems.append((number, "labels/goto require a documented measured exception"))
        if re.search(r";\s*\w+(?:\.\w+)*\s*:=", line):
            problems.append((number, "one executable statement per line"))
        if "\t" in line:
            problems.append((number, "use spaces for indentation"))
        if re.search(r"&[A-Za-z_]", line):
            problems.append((number, "avoid escaped reserved-word identifiers"))
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="*", type=Path)
    args = parser.parse_args()
    paths = args.files or (list((ROOT / "Source").glob("TFFmpeg.Media*.pas")) +
                          list((ROOT / "Source").glob("TFFmpeg.Output.pas")) +
                          list((ROOT / "Tests").glob("Media*.dpr")) +
                          list((ROOT / "Tests").glob("Media*.pas")) +
                          [path for path in (ROOT / "Examples").glob("*.dpr") if path.name != "DecodeAudio.dpr"])
    failed = False
    for path in paths:
        if "Headers" in path.parts:
            continue
        for line, message in check(path.read_text(encoding="utf-8-sig")):
            print(f"{path}:{line}: {message}", file=sys.stderr)
            failed = True
    if not failed:
        print(f"PASS: lexical Pascal style ({len(paths)} selected files; no changes)")
    return failed


if __name__ == "__main__":
    sys.exit(main())
