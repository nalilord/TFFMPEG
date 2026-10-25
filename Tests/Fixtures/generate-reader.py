#!/usr/bin/env python3
"""Original timing, format and color fixtures from a local FFmpeg CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "Bin/fixtures")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[0]

    def run(arguments):
        subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *map(str, arguments)], check=True)

    with tempfile.TemporaryDirectory(prefix="tffmpeg-reader-fixtures-") as directory:
        temporary = Path(directory)
        frames = temporary / "frames.rgb"
        frames.write_bytes(b"".join(bytes((30 + index * 17, 20 + index * 13, 10 + index * 11)) * (32 * 24) for index in range(12)))
        video_input = ["-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "32x24", "-framerate", "10", "-i", frames]
        x264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "12", "-pix_fmt", "yuv420p", "-bf", "2", "-g", "12",
                "-threads", "1", "-x264-params", "b-adapt=0:scenecut=0:colorprim=bt709:transfer=iec61966-2-1:colormatrix=bt709",
                "-flags:v", "+bitexact", "-fflags", "+bitexact"]
        run([*video_input, "-vf", "scale=out_color_matrix=bt709:out_range=tv", *x264, output / "reordered.mp4"])
        run([*video_input, "-frames:v", "5", "-vf",
             "scale=out_color_matrix=bt709:out_range=tv,settb=1/1000,setpts='if(eq(N,0),0,if(eq(N,1),100,if(eq(N,2),350,if(eq(N,3),400,900))))'",
             "-fps_mode", "vfr", "-enc_time_base", "1/1000", "-video_track_timescale", "1000", *x264, output / "vfr.mp4"])
        run([*video_input, "-itsoffset", "5.25", "-i", output / "markers.wav", "-copyts", "-vf", "setpts=PTS+5/TB",
             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "ffv1", "-level", "3", "-c:a", "pcm_s16le", "-threads", "1",
             "-flags:v", "+bitexact", "-fflags", "+bitexact", output / "offsets.mkv"])
        run(["-i", output / "reordered.mp4", "-c:v", "copy", "-bsf:v", "h264_mp4toannexb", "-f", "h264", output / "unclocked.h264"])
        # Two independently encoded elementary sequences change decoded dimensions.
        segments = []
        for index, size in enumerate(("32x24", "64x48")):
            segment = temporary / f"segment{index}.h264"
            run([*video_input, "-frames:v", "3", "-vf", f"scale={size.replace('x', ':')}", "-c:v", "libx264", "-preset", "ultrafast",
                 "-crf", "0", "-threads", "1", "-bf", "0", "-g", "1", "-flags:v", "+bitexact", "-fflags", "+bitexact", "-f", "h264", segment])
            segments.append(segment.read_bytes())
        (output / "format-change.h264").write_bytes(b"".join(segments))
        run(["-r", "10", "-fflags", "+genpts", "-i", output / "format-change.h264", "-c:v", "copy",
             "-fflags", "+bitexact", "-f", "mpegts", output / "format-change.ts"])
        run(["-i", output / "markers.wav", "-af", "asetnsamples=n=600:p=0,asetpts=PTS+gte(N\\,1200)*0.05/TB",
             "-c:a", "pcm_s16le", "-threads", "1", "-flags:a", "+bitexact", "-fflags", "+bitexact", output / "audio-gap.mka"])
        audio_segments = []
        for index, (rate, channels) in enumerate(((24000, 1), (48000, 2))):
            segment = temporary / f"audio{index}.aac"
            run(["-i", output / "markers.wav", "-ar", str(rate), "-ac", str(channels), "-c:a", "aac", "-b:a", "64k",
                 "-flags:a", "+bitexact", "-fflags", "+bitexact", "-f", "adts", segment])
            audio_segments.append(segment.read_bytes())
        (output / "audio-change.aac").write_bytes(b"".join(audio_segments))
        with wave.open(str(output / "markers.wav"), "rb") as stream:
            samples = struct.unpack("<2400h", stream.readframes(2400))
        reverse = temporary / "reverse.wav"
        with wave.open(str(reverse), "wb") as stream:
            stream.setparams((1, 2, 24000, 2400, "NONE", "not compressed"))
            stream.writeframes(struct.pack("<2400h", *(-value for value in samples)))
        blue = temporary / "blue.rgb"
        blue.write_bytes(bytes((0, 0, 255)) * (16 * 12 * 3))
        run([*video_input, "-i", output / "markers.wav", "-i", reverse, "-f", "rawvideo", "-pixel_format", "rgb24",
             "-video_size", "16x12", "-framerate", "10", "-i", blue, "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-map", "3:v:0",
             "-c:v", "ffv1", "-level", "3", "-c:a", "pcm_s16le", "-threads", "1", "-disposition:a:0", "0", "-disposition:a:1", "default",
             "-disposition:v:0", "default", "-disposition:v:1", "0", "-flags:v", "+bitexact", "-fflags", "+bitexact", output / "tracks.mkv"])
        # Preserve the known sample values as YUV and tag matrix/range explicitly.
        for name, matrix, range_name, yuv in (("sdr709.mkv", "bt709", "tv", (81, 90, 240)),
                                              ("sdr601.mkv", "smpte170m", "tv", (81, 90, 240)),
                                              ("full709.mkv", "bt709", "pc", (81, 90, 240))):
            raw = temporary / (name + ".yuv")
            raw.write_bytes(bytes([yuv[0]]) * (16 * 16) + bytes([yuv[1]]) * 64 + bytes([yuv[2]]) * 64)
            run(["-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", "16x16", "-framerate", "1", "-i", raw,
                 "-vf", f"setparams=colorspace={matrix}:range={'limited' if range_name == 'tv' else 'full'}:color_primaries=bt709:color_trc=iec61966-2-1",
                 "-c:v", "ffv1", "-threads", "1", "-colorspace", matrix, "-color_range", range_name,
                 "-color_primaries", "bt709", "-color_trc", "iec61966-2-1", "-flags:v", "+bitexact", "-fflags", "+bitexact", output / name])
        run([*video_input, "-frames:v", "1", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "0", "-pix_fmt", "yuv420p", "-threads", "1",
             "-x264-params", "transfer=smpte2084:colorprim=bt2020:colormatrix=bt2020nc", "-flags:v", "+bitexact", "-fflags", "+bitexact",
             output / "hdr-pq.mp4"])
        # A JPEG with original minimal EXIF orientation 6 (90 degrees clockwise).
        jpeg = temporary / "base.jpg"
        run(["-i", output / "colors.bmp", "-c:v", "mjpeg", "-q:v", "1", "-threads", "1", "-flags:v", "+bitexact", "-fflags", "+bitexact", jpeg])
        tiff = b"II" + struct.pack("<HIH", 42, 8, 1) + struct.pack("<HHIHHI", 0x112, 3, 1, 6, 0, 0)
        exif = b"Exif\0\0" + tiff
        encoded = jpeg.read_bytes()
        (output / "exif.jpg").write_bytes(encoded[:2] + b"\xff\xe1" + struct.pack(">H", len(exif) + 2) + exif + encoded[2:])

    names = ("reordered.mp4", "vfr.mp4", "offsets.mkv", "unclocked.h264", "format-change.h264", "audio-change.aac", "tracks.mkv",
             "sdr709.mkv", "sdr601.mkv", "full709.mkv", "hdr-pq.mp4", "exif.jpg", "format-change.ts", "audio-gap.mka")
    record = {"generator": version, "sha256": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in names}}
    (output / "reader-generation.json").write_text(json.dumps(record, indent=2) + "\n")
    expected_path = Path(__file__).with_name("reader-hashes.json")
    if expected_path.exists() and json.loads(expected_path.read_text()) != record:
        raise SystemExit("Reader fixture version/hash mismatch; review Bin/fixtures/reader-generation.json")
    print(f"PASS: {len(names)} original reader fixtures generated using {version}")


if __name__ == "__main__":
    main()
