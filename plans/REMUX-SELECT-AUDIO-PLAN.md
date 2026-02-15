# Remux with Audio Track Selection Plan

## Objective

Add a helper script that takes a **single** video file, lists its **audio** tracks, lets the user choose which to keep, and remuxes to an MP4 that drops the unwanted audio—**without transcoding** (stream copy). Output is Boiler-compatible so the result can be handed to Boiler for batch transcoding. Primary use case: drop commentary or extra language tracks to reduce file size before encoding.

**Status**: Implemented. Output container matches input; all subtitles preserved when not MP4. Keep-all = no-op; video mapping by output format (MP4: first video only + confirmation when multiple; non-MP4: only streams with valid dimensions); video streams shown in header.

---

## Current state (resume here)

**Script:** `remux-select-audio.sh` (repo root). Single-file remux with audio track selection; output `{base}.remux.{ext}` in same dir (ext matches input: .mkv, .mp4, .webm); original file never deleted.

**Done:**
- CLI (one file, `-h`), requirements (ffmpeg/ffprobe), probe audio (CSV), 0/1-audio early exit, display + prompt, validation, video codec check, output path, ffmpeg build/run, HEVC tag only when exactly one video stream and it's HEVC, success message, README/PLAN, smoke tests in legacy + Bats.
- Post–manual-test fixes: map first video only for MP4 (attached-pic streams break MP4); `-tag:v hvc1` only when one video stream and HEVC.
- Keep-all = no-op: when user selects `all` or empty, exit 0 with "Keeping all audio tracks; nothing to do."; no remux.
- Video mapping: MP4 → `-map 0:v:0`; non-MP4 → only video streams with valid width/height (`get_muxable_video_stream_indices`) to avoid attached-pic streams with no dimensions breaking the Matroska muxer. MP4 + multiple video streams → warn and require user to type `yes` before remuxing.
- Video streams in header: `probe_video_streams`; "Video streams:" section (numbered, 1-based) above "Audio tracks:" in the display.
- Bats test added for keep-all no-op. User input trim uses `sed` instead of `xargs` (avoids failures in some environments e.g. Bats sandbox).

**Remaining (next session):**
1. **Manual test**: Run on a real multi-track file (e.g. MKV with multiple audio + subtitles); select one audio; confirm remux completes, output plays, all subtitles present, and optionally that Boiler accepts it. Then commit if desired.

**Key locations in script:**
- FFmpeg map building: video map branches on `output_format` (MP4: `-map 0:v:0`; non-MP4: loop over `get_muxable_video_stream_indices`); then selected `-map 0:a:N`; then subtitles; `-c copy`; MP4-only options when output_format is mp4.
- Helpers: `get_video_codec`, `is_codec_mp4_compatible`, `count_video_streams`, `get_muxable_video_stream_indices`, `probe_video_streams`, `probe_audio_streams`, `count_audio_streams`, `get_output_format_from_input`, `probe_subtitle_codecs`, `is_subtitle_codec_mp4_compatible`.

---

## Scope (v1)

- **Single file only**: Script accepts exactly one input path. No batching, no directory traversal, no `-L`/max-depth.
- **Audio only**: List and select audio tracks. **Keep all subtitles**: copy all subtitle streams to the output (no subtitle listing or selection in v1).
- **Boiler-compatible output**: Output is suitable for Boiler (which accepts non-MP4). **Current**: script forces MP4 (same rules as remux-only); some subtitles (e.g. SubRip) are skipped. **Planned**: output same container as input (e.g. MKV → MKV) when that preserves all subtitles; only use MP4-specific rules when output is MP4.

## Requirements

1. **CLI**: One positional argument (input file). Optional `-h`/`--help`. Exit with clear error if zero or multiple files given.
2. **Probe**: Use ffprobe to list audio streams only (index, codec, language/title when available).
3. **Interaction**: Display numbered audio tracks; prompt user for which to keep (e.g. `1,3` or `all`). Parse and validate.
4. **Remux**: Build explicit `-map 0:v:0` (first video stream only), `-map 0:a:N` for selected audio, `-map 0:s` (all subtitle streams); `-c copy`; same MP4/faststart/HEVC rules as Boiler/remux-only.
5. **Output path**: Consistent, Boiler-friendly filename (e.g. same directory; naming convention TBD in tasks—e.g. `{base}.remux.mp4` or reuse `.orig.{bitrate}.Mbps.mp4` if bitrate is computed).
6. **Codec compatibility**: Only remux when video (and selected audio) are MP4-copyable; skip or error with clear message otherwise (reuse same logic as remux-only where applicable).

## Todos (execution order)

- [x] **Create script file**  
  Add e.g. `remux-select-audio.sh` in repo root (alongside `remux-only.sh`, `cleanup-originals.sh`). Shebang `#!/bin/bash`, `set -e`. Brief comment at top: purpose (single-file remux with audio track selection, Boiler-compatible output).

- [x] **Argument parsing**  
  Require exactly one positional argument (input file path). Support `-h`/`--help` to print usage and exit. If no args or more than one non-option arg: print usage to stderr and exit non-zero. Usage line: e.g. `Usage: $0 [-h] <video_file>`.

- [x] **Requirements check**  
  Ensure `ffmpeg` and `ffprobe` are in PATH; exit with clear error if not. No need for `bc` unless output naming uses bitrate (see output-path task).

- [x] **Probe audio streams**  
  Use ffprobe to list audio streams: at least `index` (stream index within file), `codec_name`, and optional `stream_tags=language,title`. Prefer machine-parseable output (e.g. `-of json` or `-of csv`) and parse in bash. Store 0-based audio stream indices and human-readable labels (codec + language/title) for display.

- [x] **Handle nothing-to-do cases**  
  If file has **zero** audio streams or **exactly one** audio track: print a clear informational message (e.g. "No audio tracks to select" / "Only one audio track, nothing to do") and exit with **exit code 0** (conventional "success / nothing to do"). Do not prompt or remux in these cases.

- [x] **Display audio tracks and prompt**  
  Print a simple numbered list (1-based for user), e.g. `1: English (aac)`, `2: Commentary (aac)`. Then prompt: e.g. `Audio tracks to keep (e.g. 1,3 or 'all'): `. Accept `all` (or empty) to keep every audio track. Parse comma-separated indices and convert to 0-based for mapping.

- [x] **Validate chosen indices**  
  Reject invalid input (non-numeric, out of range, duplicate). On invalid input: re-prompt or exit with error (choose one and be consistent). If user selects "keep none": either disallow and re-prompt, or allow and produce video-only output (document choice).

- [x] **Video codec compatibility**  
  Before remuxing, probe video codec and ensure it is MP4-copyable (same rule as remux-only: e.g. reject wmv3, vc1, theora, etc.). If incompatible, print clear error and exit without overwriting. Optionally check selected audio codecs are copyable into MP4 (or rely on ffmpeg to fail and surface error).

- [x] **Output path**  
  Decide output filename convention. Options: (a) `{base}.remux.mp4`, (b) `{base}.orig.{bitrate}.Mbps.mp4` (requires duration/bitrate like remux-only). Document in script comment. Ensure output is in same directory as input; avoid overwriting input (abort or use a distinct name).

- [x] **Build and run ffmpeg**  
  Build command: `-i "$input"`, then `-map 0:v:0` (first video stream only), one `-map 0:a:N` per selected audio index (0-based N), then `-map 0:s` (all subtitles). Then `-c copy`, `-movflags +faststart`, `-f mp4`, `"$output"`. If first video stream is HEVC/H.265, add `-tag:v hvc1`. Run ffmpeg; exit non-zero on failure; do not remove or overwrite input on failure or success (original always preserved).

- [x] **Success message**  
  After a successful remux, print a success message. Copy or emulate the other helper scripts: e.g. remux-only uses `info "  ✓ Successfully remuxed and removed original"`; include the output file path so the user can hand the file to Boiler.

- [x] **Documentation**  
  - In README (or "Helper scripts" section): add one line or short paragraph describing `remux-select-audio.sh` (single file, pick audio tracks, remux to Boiler-compatible MP4).
  - In PLAN.md or PROJECT-CONTEXT: optional one-line under helpers or future-work if you track helper scripts there.

- [x] **Smoke test**  
  Add smoke tests for the script in **both** the legacy suite (`test_boiler.sh`) and the Bats suite (`tests/`). Test at least: (1) invocation with `-h` exits 0 and prints usage; (2) invocation with no args exits non-zero; (3) invocation with a file that has zero or one audio track exits 0 with "nothing to do" style message. Because the script is destructive by nature (it produces a file that replaces or becomes the target for Boiler), having coverage in both suites is warranted. Use testdata or a minimal fixture if needed; avoid requiring real multi-track video in CI.

- [x] **Keep all subtitles**  
  Add `-map 0:s` to the ffmpeg command so all subtitle streams are copied to the output. No subtitle listing or selection in v1—copy every subtitle stream. Ensures remux keeps subtitles while user only selects which audio tracks to keep.

- [x] **Don’t force MP4 (preserve all subtitles)**  
  When input is a container that supports all subtitle codecs (e.g. Matroska), output the same container (e.g. `{base}.remux.mkv`) instead of MP4. Use `-map 0:s` without filtering; no need to skip SubRip/SRT. Only when output is MP4 apply: `-movflags +faststart`, `-tag:v hvc1` when HEVC, and restrict subtitles to mov_text. Boiler accepts MKV/other input.

- [x] **Keep-all = no-op**  
  When the user selects `all` or presses Enter (keeping every audio track), treat as nothing to do: print an informational message (e.g. “Keeping all audio tracks; nothing to do.”) and exit with code 0. Do not remux. Aligns with 0/1 audio early-exit behavior and avoids creating a file when the user did not choose to drop any audio.

- [x] **Video: strip only when MP4; warn and require confirmation when stripping**  
  When output format is **not** MP4 (e.g. Matroska, webm), use `-map 0:v` so all video streams are copied (no silent dropping of a second real video track). When output format **is** MP4, keep using `-map 0:v:0` (MP4 muxer can fail on attached-pic streams). If output is MP4 and the file has more than one video stream, before building/running ffmpeg: print a clear warning that only the first video stream will be included and others will be dropped, and require the user to type `yes` to continue; if they do not type `yes`, exit without remuxing (e.g. exit 0 with “Aborted.” or similar).

- [x] **Video streams in header**  
  When presenting the “dashboard” to the user (the screen where they choose audio tracks), show video stream information at the top. Add a helper (e.g. `probe_video_streams`) that uses ffprobe to list video streams with a short label per stream (e.g. codec_name and optional stream_tags title/filename). Display a “Video streams:” section (numbered, 1-based) above “Audio tracks:” so the user sees what video streams exist before choosing audio. Ensures the user understands what “first video stream” means when we strip to one (MP4 case).

- [ ] **Manual test**  
  Run script on a file with multiple audio tracks (e.g. main + commentary); select one track; confirm output is smaller, plays correctly, includes all subtitles, and is accepted by Boiler (or at least has correct container/codec).

## Out of Scope (v1)

- **Batching / multiple files**: Single file only.
- **Subtitle selection**: No listing or picking which subtitles to keep; v1 copies all subtitle streams. Per-track subtitle selection deferred.
- **Structural clone of remux-only.sh**: No depth, no discovery, no shared sourcing; only output compatibility.

## Success Criteria

- User can run `./remux-select-audio.sh path/to/file.mkv`, see audio tracks listed, choose e.g. track 1 only, and get a single MP4 with only that audio (and all video). File is smaller when commentary/secondary tracks are dropped and can be passed to Boiler for further transcoding.
- Invalid input (wrong args, bad indices) produces clear errors and does not corrupt or overwrite the source file.
- Zero or one audio track: script exits with code 0 and an informational "nothing to do" message; no remux attempted.
- Success message after remux matches the style of other helpers (e.g. "✓ Successfully remuxed..." with output path).
- Smoke tests exist in **both** legacy and Bats suites; they cover at least: `-h` (exit 0), no args (exit non-zero), and nothing-to-do (0 or 1 audio track, exit 0).
- Output includes **all subtitle streams** from the source when output container supports them (e.g. MKV preserves SubRip/SRT). When output is forced to MP4, only mov_text subtitles are preserved; others are skipped (planned: avoid forcing MP4 to preserve all).

---

## Findings (manual testing)

- **HEVC tag with multiple video streams**: If the source has more than one video stream (e.g. main + thumbnail or mixed codecs), applying `-tag:v hvc1` to all caused `Tag hvc1 incompatible with output codec id '7' (mp4v)`. **Fix applied**: only add `-tag:v hvc1` when there is exactly one video stream and it is HEVC; otherwise omit the tag.
- **Attached-pic / cover-art streams**: Sources (e.g. Blu-ray-style MKV) can have MJPEG “attached pic” video streams (cover art, posters). Mapping all video with `-map 0:v` pulled those in; some have no dimensions (`none`), which broke the MP4 muxer: “dimensions not set”, “Could not write header”. **Fix applied**: map only the first video stream (`-map 0:v:0`) so the main movie is copied and attached pictures are skipped.
- **Subtitles dropped**: The script only mapped video and selected audio; no subtitle mapping, so output had `subtitle:0KiB`. User expectation: drop only unwanted audio; keep all subtitles. **Planned**: add `-map 0:s` to copy all subtitle streams (no selection in v1).
- **Opus parsing messages**: When remuxing Opus audio into MP4, ffmpeg may print `[opus @ ...] Error parsing Opus packet header`; remux can still complete and play. Treat as benign unless playback is wrong.
- **Original file**: Confirmed the original input is never deleted; it is preserved on both success and failure. Output is always a new file (`{base}.remux.mp4`).
- **SubRip in MP4**: MP4 does not support stream-copy of SubRip/SRT; FFmpeg fails with “Could not find tag for codec subrip”. Script was updated to copy only mov_text subtitles when output is MP4 and to warn when tracks are skipped. **Done**: output same container as input (e.g. MKV → MKV) so `-map 0:s` preserves all subtitles.
- **Non-MP4 with `-map 0:v` (all video)**: MKV sources (e.g. Blu-ray-style) can have one real video stream plus several attached-pic streams (cover art). Some attached-pic streams have no width/height (`none`). Using `-map 0:v` for non-MP4 copied those and the Matroska muxer failed: "dimensions not set", "Could not write header". **Fix applied**: for non-MP4, only map video streams that have valid width and height (helper `get_muxable_video_stream_indices` using ffprobe `stream=width,height`); skip streams with missing/zero dimensions. Exit with error if no muxable video streams.
- **User input trim**: Script originally used `xargs` to trim the "Audio tracks to keep" input; in some environments (e.g. Bats sandbox) `xargs` can fail (e.g. `sysconf(_SC_ARG_MAX) failed`). **Fix applied**: trim with `sed` instead of `xargs`.

---

## Avoid forcing MP4 (implemented)

**Problem:** Forcing output to MP4 forced us to drop SubRip/SRT (and other non–mov_text) subtitles, because MP4 cannot stream-copy them.

**Implemented:** Output container is derived from input extension: `.mkv`→matroska/`.mkv`, `.mp4`/`.m4v`/`.mov`→mp4/`.mp4`, `.webm`→webm/`.webm`, unknown→matroska/`.mkv`. When output is not MP4 we use `-map 0:s` (all subtitles). When output is MP4 we keep mov_text-only subtitle mapping, `-movflags +faststart`, and `-tag:v hvc1` when HEVC. Helper `get_output_format_from_input` returns format and extension; MP4 codec compatibility is only enforced when output format is mp4.

---

## Implemented: keep-all no-op and video behavior

**Rationale:** (1) Selecting "keep all" audio is a no-op; we exit 0 without remuxing. (2) For non-MP4 we map only video streams with valid dimensions (`get_muxable_video_stream_indices`), so we don't copy attached-pic streams with no dimensions (they break the Matroska muxer—see Findings). For MP4 we use `-map 0:v:0`. (3) When MP4 + multiple video streams, we warn and require user to type `yes` before remuxing. (4) "Video streams:" section appears in the header above "Audio tracks:" via `probe_video_streams`.

**Tests:** Legacy and Bats suites pass. Bats includes a keep-all no-op test (multi-track file, echo "all" into script, assert exit 0 and no remux file created).

---
## Session handoff / Implementation notes

**When resuming:** Read `PROJECT-CONTEXT.md` (testing before commit is mandatory) and this plan’s “Current state (resume here)” above. **Next work:** Run manual test on a real multi-track file (e.g. MKV with multiple audio + subtitles; Blockers-style). Select one audio track; confirm remux completes without "dimensions not set" or mux errors, output plays, and all expected subtitles are present. Run `bash test_boiler.sh` and `bats tests/test_remux_select_audio_smoke.bats` before commit. No further implementation tasks for this feature set unless manual test reveals issues.

**Reuse from remux-only.sh (already done in script):**
- Video codec: `get_video_codec()` (ffprobe `-select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1`).
- MP4 compatibility: `is_codec_mp4_compatible()` (reject wmv3, wmv1, wmv2, vc1, rv40, rv30, theora; allow h264, hevc, h265, mpeg4, avc1, etc.).
- After building `-map` list: `-c copy`, `-movflags +faststart`, `-f mp4`; add `-tag:v hvc1` when video codec is hevc/h265.
- Logging: `info`/`warn`/`error` with GREEN/YELLOW/RED and `NC` (see top of remux-only.sh).

**Listing audio streams (ffprobe):**  
Use `-select_streams a` and machine-parseable output. Example (JSON):  
`ffprobe -v error -select_streams a -show_entries stream=index,codec_name:stream_tags=language,title -of json "$input"`.  
Audio stream indices in ffmpeg are 0-based within type (e.g. first audio = `0:a:0`, second = `0:a:1`). Parse and display 1-based to user; convert back to 0-based for `-map 0:a:N`.

**Output naming:**  
Recommend `{base}.remux.mp4` (same directory as input). No bitrate/duration needed; keeps script simple and no `bc` dependency. Reject if output path equals input (or would overwrite input).

**Smoke-test fixtures:**  
Repo `testdata/` has no video files (only `video-attribution-cc-license.txt`). For “0 or 1 audio track” tests, create minimal files in a temp dir: (1) one audio track: `ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 -c:a aac -y /tmp/one_audio.mp4`; (2) zero audio: e.g. `ffmpeg -f lavfi -i color=c=black:s=320x240:d=1 -c:v libx264 -y /tmp/no_audio.mp4`. Then run script on those paths and assert exit 0 and “nothing to do” message. No real multi-track video required for CI.

**Test order:**  
Implement the script and complete tasks through “Success message” before adding smoke tests. Then add legacy tests in `test_boiler.sh`, then Bats tests in `tests/` (e.g. `tests/test_remux_select_audio_smoke.bats` or similar). Run `bash test_boiler.sh` and `run-bats-tests.sh` (or `bats tests/*.bats`) before committing; PROJECT-CONTEXT requires both pass.

**Other helpers:**  
No other non-boiler scripts (remux-only, cleanup-originals, copy-1080p-test, etc.) are currently covered by legacy or Bats tests. This script will be the first helper with test coverage.

**Subtitles:** Already implemented: when output is MP4, only mov_text subtitles are mapped; when output is not MP4, `-map 0:s` copies all. See “Key locations” and “Avoid forcing MP4” above.
