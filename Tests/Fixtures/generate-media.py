#!/usr/bin/env python3
"""Generate original container fixtures with a local FFmpeg CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "Bin/fixtures")
    args = parser.parse_args()
    output = args.output.resolve()
    subprocess.run(["python3", str(Path(__file__).with_name("generate.py")), "--output", str(output)], check=True)
    version = subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[0]

    def run(arguments):
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *map(str, arguments)], check=True)

    with tempfile.TemporaryDirectory(prefix="tffmpeg-fixtures-") as directory:
        temporary = Path(directory)
        frames = temporary / "frames.rgb"
        frames.write_bytes(b"".join(bytes(color) * (16 * 12) for color in ((255, 0, 0), (0, 255, 0), (0, 0, 255))))
        attachment = temporary / "original.bin"
        attachment.write_bytes(b"TFFMPEG original synthetic attachment\n")
        video_input = ["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "16x12", "-framerate", "10", "-i", frames]
        lossless = ["-c:v", "ffv1", "-level", "3", "-threads", "1", "-flags:v", "+bitexact", "-fflags", "+bitexact"]
        run([*video_input, *lossless, "-metadata", "title=Original synthetic video", output / "video.mkv"])
        run([*video_input, "-i", output / "markers.wav", "-map", "0:v:0", "-map", "1:a:0", "-map", "1:a:0",
             *lossless, "-c:a", "pcm_s16le", "-attach", attachment, "-metadata:s:t", "mimetype=application/octet-stream",
             "-metadata", "title=Original synthetic multistream", "-metadata:s:a:0", "language=eng",
             "-metadata:s:a:1", "language=deu", "-disposition:a:0", "0", "-disposition:a:1", "default",
             output / "multi.mkv"])
        # MP3 carries a PNG attached picture, not an ordinary video track.
        run(["-i", output / "markers.wav", "-i", output / "colors.bmp", "-map", "0:a:0", "-map", "1:v:0",
             "-c:a", "libmp3lame", "-b:a", "64k", "-c:v", "png", "-threads:v", "1", "-disposition:v", "attached_pic",
             "-flags:v", "+bitexact", "-fflags", "+bitexact", "-id3v2_version", "3", output / "cover.mp3"])
        # MOV stores a display matrix; MP4 remux explicitly installs rotation.
        run([*video_input, "-c:v", "libx264", "-preset", "ultrafast", "-crf", "0", "-pix_fmt", "yuv420p", "-threads", "1",
             "-vf", "setsar=2/1", "-color_primaries", "bt709", "-colorspace", "bt709", "-color_trc", "bt709",
             "-color_range", "tv", "-flags:v", "+bitexact", "-fflags", "+bitexact", temporary / "base.mp4"])
        run(["-display_rotation:v:0", "90", "-i", temporary / "base.mp4", "-c", "copy", "-fflags", "+bitexact",
             output / "rotated.mp4"])

    names = ("video.mkv", "multi.mkv", "cover.mp3", "rotated.mp4")
    hashes = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in names}
    (output / "media-generation.json").write_text(json.dumps({"generator": version, "sha256": hashes}, indent=2) + "\n")
    expected = json.loads(Path(__file__).with_name("media-hashes.json").read_text()) if Path(__file__).with_name("media-hashes.json").exists() else None
    if expected is not None and (expected["generator"] != version or expected["sha256"] != hashes):
        raise SystemExit("Fixture generator version/hash mismatch; review Bin/fixtures/media-generation.json before qualification")
    print(f"PASS: {len(hashes)} container fixtures generated using {version}")


if __name__ == "__main__":
    main()
