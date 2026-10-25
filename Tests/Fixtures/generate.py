#!/usr/bin/env python3
"""Generate original, deterministic PCM/BMP fixtures without external codecs."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import wave


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    # 100 ms mono PCM: square wave with distinct first and last markers.
    samples = [12000 if (index // 12) % 2 else -12000 for index in range(2400)]
    samples[0] = 1234
    samples[-1] = -2345
    with wave.open(str(output / "markers.wav"), "wb") as stream:
        stream.setparams((1, 2, 24000, 2400, "NONE", "not compressed"))
        stream.writeframes(struct.pack("<2400h", *samples))
    with wave.open(str(output / "channels33.wav"), "wb") as stream:
        stream.setparams((33, 2, 24000, 2400, "NONE", "not compressed"))
        stream.writeframes(b"".join(struct.pack("<h", sample) * 33 for sample in samples))
    # Bottom-up 3x2 BMP, padded to 12 bytes per row. Top: red, green, blue.
    pixels = bytes([255, 255, 255, 0, 0, 0, 0, 255, 255, 0, 0, 0,
                    0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0])
    header = b"BM" + struct.pack("<IHHI", 54 + len(pixels), 0, 0, 54)
    header += struct.pack("<IiiHHIIiiII", 40, 3, 2, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    (output / "colors.bmp").write_bytes(header + pixels)
    return {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
            for name in ("markers.wav", "colors.bmp", "channels33.wav")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "Bin/fixtures")
    args = parser.parse_args()
    actual = generate(args.output)
    expected = json.loads(Path(__file__).with_name("hashes.json").read_text())
    if actual != expected:
        raise SystemExit(f"Fixture hashes differ: {actual}")
    print(f"PASS: {len(actual)} deterministic fixtures verified in {args.output}")


if __name__ == "__main__":
    main()
