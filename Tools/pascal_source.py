#!/usr/bin/env python3
"""Small Pascal lexer shared by non-mutating project audits.

Comments, compiler directives and quoted strings are recognized before code.
This is deliberately not a Pascal parser or preprocessor: both conditional
branches are checked, and include directives require manual dependency review.
"""
from dataclasses import dataclass
import re


@dataclass(frozen=True)
class Token:
    value: str
    start: int
    line: int
    kind: str = "code"


TOKEN = re.compile(
    r"//[^\n]*|\{[^}]*\}|\(\*.*?\*\)|'(?:''|[^'])*'|"
    r"[A-Za-z_][A-Za-z_0-9]*|:=|[^\s]", re.DOTALL)


def tokens(source):
    for match in TOKEN.finditer(source):
        value = match.group()
        kind = "code"
        if value.startswith(("//", "{", "(*")):
            kind = "comment"
        elif value.startswith("'"):
            kind = "string"
        yield Token(value, match.start(), source.count("\n", 0, match.start()) + 1, kind)


def code_tokens(source):
    return [token for token in tokens(source) if token.kind == "code"]


def masked_code(source):
    result = list(source)
    for token in tokens(source):
        if token.kind != "code":
            for index in range(token.start, token.start + len(token.value)):
                if result[index] != "\n":
                    result[index] = " "
    return "".join(result)


def imports(source, interface_only=False):
    code = code_tokens(source)
    if interface_only:
        start = next((i + 1 for i, t in enumerate(code) if t.value.lower() == "interface"), len(code))
        end = next((i for i in range(start, len(code)) if code[i].value.lower() == "implementation"), len(code))
        code = code[start:end]
    result = []
    in_uses = False
    name = []
    for token in code:
        if token.value.lower() == "uses":
            in_uses = True
        elif in_uses:
            if token.value in (",", ";"):
                if name:
                    result.append("".join(name))
                name = []
                if token.value == ";":
                    in_uses = False
            else:
                name.append(token.value)
    return result
