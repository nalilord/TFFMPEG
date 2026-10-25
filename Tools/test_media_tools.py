#!/usr/bin/env python3
"""Regression tests for audits: source must be treated as Pascal, not plain text."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

from pascal_source import imports


def tool(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parent / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


style = tool("check-code-style")
boundary = tool("check-media-boundary")


class MediaToolsTests(unittest.TestCase):
    def test_literals_comments_directives_and_external_names(self):
        source = """unit Demo;
{$IFDEF lowercase_and_or}
// x := array of string; goto x; uses libavcodec;
{ (* x := string *) }
(* x := string; *)
const
  TextValue = 'don''t change array of string := or PAVFrame';
begin
  TextValue:='';
  avcodec_send_packet(Context, nil);
  if AValue AND NOT BValue then
    WriteLn(TextValue);
end.
"""
        before = source.encode()
        self.assertEqual(style.check(source), [])
        self.assertEqual(source.encode(), before)

    def test_bad_code(self):
        self.assertTrue(style.check("x := 1; y:=2; if x and y then writeln('x');"))
        self.assertTrue(style.check("for var I:=0 to 3 do"))
        self.assertTrue(style.check("var Value:=3;"))

    def test_conditional_imports_and_implementation_boundary(self):
        source = """unit Example; interface uses {$IFDEF FPC} SysUtils, {$ELSE} System.SysUtils, {$ENDIF}
TFFmpeg.Media.Types; implementation uses libavcodec; end."""
        self.assertEqual(imports(source, True), ["SysUtils", "System.SysUtils", "TFFmpeg.Media.Types"])

    def test_native_and_transitive_leaks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Source").mkdir()
            first = root / "Source/TFFmpeg.Media.pas"
            second = root / "Source/TFFmpeg.Media.Other.pas"
            first.write_text("unit TFFmpeg.Media; interface uses TFFmpeg.Media.Other; implementation end.")
            second.write_text("unit TFFmpeg.Media.Other; interface uses TFFmpeg.Input; type X = PAVFrame; implementation end.")
            problems = boundary.audit(root)
            self.assertTrue(any("TFFmpeg.Input" in p for p in problems))
            self.assertTrue(any("PAVFrame" in p for p in problems))
            second.write_text("unit TFFmpeg.Media.Other; interface uses SysUtils; implementation uses libavcodec; end.")
            self.assertEqual(boundary.audit(root), [])
            second.write_text("unit TFFmpeg.Media.Other; interface {$I hidden.inc} implementation end.")
            self.assertTrue(any("source includes" in p for p in boundary.audit(root)))
            second.write_text("unit TFFmpeg.Media.Other; interface implementation {$I private.inc} end.")
            self.assertEqual(boundary.audit(root), [])
            consumer = root / "Example.dpr"
            consumer.write_text("program Example; uses TFFmpeg.Media.Internal.Native; begin end.")
            self.assertTrue(boundary.audit(root, [consumer]))


if __name__ == "__main__":
    unittest.main()
