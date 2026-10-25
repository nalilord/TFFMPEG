# Media fixtures

Run `python3 Tests/Fixtures/generate.py` from the checkout. Python 3's standard
library writes `Bin/fixtures/markers.wav`, `channels33.wav` and `colors.bmp` and verifies SHA-256
against `hashes.json`. Output is ignored by Git; no encoded binaries are tracked.
Generation has no FFmpeg runtime dependency. The generator and original synthetic
content are covered by the repository BSD license and contain no third-party media.

`markers.wav` is PCM S16LE, mono, 24000 Hz, exactly 2400 samples (100 ms).
Samples alternate -12000/+12000 every twelve samples; the first is 1234 and the
last is -2345. There are no skip samples or codec delay. `colors.bmp` is 3 by 2,
24-bit BGR with bottom-up rows and twelve-byte stride. Displayed top row is
red/green/blue; bottom row is white/black/yellow. Header resolution is 2835 px/m.

`channels33.wav` repeats the same marker signal on 33 channels. Inspection must
preserve this layout even though selecting it for decoding exceeds the current
32-channel reader limit. It has 2400 samples per channel and 100 ms duration.

`MediaTestSupport.TMediaTestDirectory` creates a GUID-named directory in the OS
temporary directory. Tests own the helper with `try/finally`. Keep its files flat;
the destructor removes files and the directory without following subdirectories.
`MediaControlSmoke` exercises cleanup after a deliberate failure. Native diagnostic
code stays in tests, never in high-level application examples.

Run `python3 Tests/Fixtures/generate-media.py` for container fixtures. It calls the
foundation generator, then a local FFmpeg CLI. The recorded generator is FFmpeg
8.1.3 (the independent Linux CLI, not the library runtime under test), with
FFV1, PCM, libmp3lame, PNG and libx264 enabled. `media-hashes.json` pins its version
and SHA-256 output. A mismatch fails qualification and writes actual generator/hash
evidence to ignored `Bin/fixtures/media-generation.json` for review. All pixels,
audio and attachment data are original synthetic content under the repository
license. The generated artifacts are test inputs, never distributed runtimes.

- `video.mkv`: three 16x12 solid frames, red/green/blue, 10 fps, FFV1, 300 ms;
  container title `Original synthetic video`.
- `multi.mkv`: the same video at index 0, 100 ms PCM marker audio at indexes 1/2
  with languages eng/deu; only audio 2 has default disposition. Index 3 is an
  original application/octet-stream attachment named `original.bin`, codec none,
  no decoder. Container title is `Original synthetic multistream`. Matroska stream
  duration may remain unknown even when its DURATION tag is available.
- `cover.mp3`: 24 kHz mono MP3 plus a 3x2 PNG attached picture; the picture must
  never become default video. PNG decoding requires an FFmpeg runtime built with
  zlib; unavailable decoders must produce explicit selection errors.
- `rotated.mp4`: three H.264 16x12 frames, 10 fps, 300 ms, SAR 2:1, coded DAR 8:3,
  bt709 matrix/TV range, 90-degree counterclockwise display matrix. Expected matrix
  coefficients are `[0,-1,0,1,0,0,0,0,1]`. This fixture uses libx264 only during
  generation; probing needs an H.264 decoder, not an H.264 encoder.

Independent `ffprobe -v error -show_streams -show_format <fixture>` output was
checked against these expectations. Frame identity is not a claim of lossless
RGB preservation for the H.264 fixture. No external media is downloaded.

Run `python3 Tests/Fixtures/generate-reader.py` after the foundation/container
generators. `reader-hashes.json` pins generator/version/hashes. Output and
actual-generation records stay under ignored Bin/fixtures. Content remains original
synthetic media under the repository license; no public media is downloaded.

- `reordered.mp4`: twelve 32x24 H.264 frames at 10 fps, two B frames between P
  frames. Frame i has RGB (30+17*i, 20+13*i, 10+11*i); lossy RGB tolerance is five
  levels. All twelve presentation timestamps and final delayed drain are asserted.
- `vfr.mp4`: the first five source frames at exact 0/100/350/400/900 ms, with B
  frames and a 1/1000 encoder/container time base. Average frame rate must not
  replace these actual timestamps during extraction.
- `offsets.mkv`: twelve lossless 32x24 frames beginning at source time 5 seconds,
  plus the 100 ms PCM marker signal beginning at 5.25 seconds. Relative selected
  AV offset is 250 ms. Native Matroska container duration includes the leading
  source offset (6.2 s); presentation origin and source metadata remain distinct.
- `tracks.mkv`: source video at index 0, PCM marker audio at index 1, sign-inverted
  PCM at index 2 (default audio), and three 16x12 blue video frames at index 3.
  Only video 0 is default. Distinct edge samples/colors prove actual track routing.
- `unclocked.h264`: the reordered video as an elementary stream with no container
  PTS. Sequential reads preserve unknown time; time seeking fails explicitly.
- `format-change.h264`: two three-frame lossless elementary sequences, first
  32x24 then 64x48. There are six decoded frames and exactly one format-change flag.
  Native probing may expose the later SPS size; per-frame info follows actual data
  and a previously returned snapshot must not change.
- `format-change.ts`: the same six frames remuxed into MPEG-TS with generated
  10-fps timestamps. Native source starts at 1.4 seconds, changes geometry after
  frame three, and normalizes to 0/100/200/300/400/500 ms. AV conversion must
  retain all six identities at fixed target dimensions.
- `audio-gap.mka`: original PCM markers framed into four 600-sample blocks
  at 24 kHz, timestamped at 0/25/100/125 ms. The 50-ms gap must produce an explicit
  discontinuity error and abort unpublished output.
- `audio-change.aac`: concatenated original ADTS AAC segments, 24 kHz mono then
  48 kHz stereo. The reader delivers initial samples then explicitly rejects the
  input format/layout change rather than silently reinterpreting converted output.
- `sdr709.mkv`, `sdr601.mkv`, `full709.mkv`: 16x16 FFV1 YUV420 frames with every
  Y/U/V sample 81/90/240. The setparams filter changes metadata only; decoded
  native means are independently checked with showinfo. Tags are respectively
  BT.709 limited, BT.601 limited and BT.709 full, with BT.709 primaries and sRGB
  transfer. Expected decoded RGB is about (255,24,0), (254,0,0), (255,36,10), with
  tolerance two for integer scaler rounding. These are distinct range/matrix tests.
- `hdr-pq.mp4`: an original H.264 frame explicitly tagged BT.2020/PQ. SDR reads
  must reject it with an unsupported HDR error, without returning a sample.
- `exif.jpg`: a JPEG of the original color image plus a minimal, original EXIF
  TIFF orientation 6 entry (90 degrees clockwise). Display dimensions are 2x3;
  explicit coded geometry stays 3x2. JPEG color assertions use codec tolerances.

Corruption tests create truncated MP4/BMP files in owned test directories and
remove them on all paths. Encoded outputs are checked with public decoders and
independent BMP/PNG/JPEG header properties; the SDR PNG example is independently
probed for RGB/full-range, transfer and primaries tags. Writer/conversion tests also
generate owned raw PCM/video, image sequences, unknown-duration live Matroska/FLAC,
early-audio and truncated/error fixtures in their test directories. These are
removed on all paths. The reader manifest contains 14 fixtures. Device tests use
a deterministic mock source or explicitly selected live hardware; private camera
and microphone recordings are not fixtures.

When adding a fixture, record its recipe, generator version, expected properties
and hash here. For lossy encoders, record signal/timing tolerances separately from
the encoded-byte hash; byte identity alone does not establish codec correctness.
