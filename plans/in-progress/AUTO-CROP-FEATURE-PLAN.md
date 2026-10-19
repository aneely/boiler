# Auto-Crop Feature Plan: Detect and Remove Baked-in Letterboxing

## Objective

Add opt-in detection and removal of baked-in letterboxing/pillarboxing (black bars) to the existing `boiler.sh` re-encode flow. FFmpeg's `cropdetect` identifies the active picture area; the crop is applied as a `crop=` video filter in the same VideoToolbox encode that boiler already performs, so cropping costs no extra encode.

**Status**: Implemented and tested; a real-file run after the latest fixes works. Manual verification on harder real files is pending | **Priority**: High | **Effort**: Medium

## What cropping does and does not buy

- Black bars compress to almost nothing, so cropping barely shrinks a file at a fixed quality, and clean bars already receive almost no bits, so cropping does not meaningfully raise bits per visible pixel either (see [Research](#research-cost-of-black-bars-and-lossless-cropping)). The real benefits are correct aspect ratio on playback (no bars on non-matching displays), less decode work, and a small gain when bars are noisy or the bar edge is not 16-pixel aligned. **Cropping never lowers the target bitrate** (decided): the target stays at the tier default or the `--target-bitrate` value, so output size is expected to be roughly unchanged (see [Target bitrate](#target-bitrate-and-resolution-tier)).
- **Cropping always implies a re-encode.** Remuxing (`-c copy`) cannot change frame dimensions. There is no "crop-while-remuxing" path in boiler. A metadata-only crop via the HEVC/H.264 `*_metadata` bitstream filters exists but is out of scope and has unreliable player support (see [Research](#research-cost-of-black-bars-and-lossless-cropping) and [Future Enhancements](#future-enhancements-out-of-scope)).

## Interaction with existing `boiler.sh` behavior

Cropping is not just a filter on `transcode_sample()`/`transcode_full_video()`: a crop changes decisions that are made *before* those functions run. This table is the heart of the plan.

| Existing behavior | Location | Problem with crop | Resolution |
|---|---|---|---|
| Tier chosen from **height** only | `calculate_target_bitrate()` | A 1920x1080 file with 1920x800 content crops to "720p" and silently drops from 8 → 5 Mbps | Tier is chosen from **pre-crop** dimensions and the target is not scaled (see below) |
| Source within ±5% of target, or below target → no transcode, file renamed `.orig.` | `transcode_video()` (two early-return blocks) | Crop forces a re-encode, so these short-circuits must not fire when a crop is detected | Run crop detection **before** the short-circuit checks; if crop is applied, skip both early returns and fall through to the transcode section |
| Non-QuickLook containers within tolerance are remuxed and marked `.orig.` | `preprocess_non_quicklook_files()` → `handle_non_quicklook_at_target()` | Runs *before* `transcode_video()`; once remuxed to `.orig.` the file is skipped forever, so crop would never be considered | With `--auto-crop`, preprocess must run detection first and leave the file alone (not remux) when a crop is detected, so the main pass re-encodes it directly from the source |
| Files marked `.fmpg.`/`.orig.`/`.hbrk.` are skipped | `should_skip_file()` | Already-processed files are never re-cropped | Accepted limitation, documented. `--crop-detect-only` uses the same discovery as a normal run (boiler.sh takes no file arguments), so it also skips marked files; explicit-file detection is deferred to the subcommand interface |
| Quality search transcodes 60 s samples with `transcode_sample()` | `find_optimal_quality()` | If samples are uncropped but the final encode is cropped, the bitrate prediction is wrong | Crop is applied identically in samples and full encode (single source of truth: `CROP_PARAMS` global) |
| 3 passes of `transcode_full_video()` | `transcode_video()` | Each pass must apply the same crop | Same global; set once per file |
| Display helpers print to stderr so `$()` captures only return values | `info`/`warn`/`error`, `calculate_sample_points` | Detection function returns its result on stdout | `detect_black_bars()` returns the crop string on stdout and logs only via `info`/`warn` (already stderr). Never `echo` diagnostics to stdout |
| Existing PLAN.md item "Aspect ratio corner case handling" | `PLAN.md` | Both features change how resolution maps to a tier | Land them with one shared definition of "effective resolution" (see below); do not implement two competing rules |

## Requirements

### User requirements
1. **Opt-in**: nothing changes unless `--auto-crop` is passed.
2. **Conservative**: only crop when bars total at least `CROP_MIN_REMOVED_PCT` (default 3%) of the frame area. Smaller detections are ignored.
3. **Never cut picture**: when in doubt, crop less or not at all. A missed crop is cheap; a cropped-off picture is not recoverable (originals are preserved, but the user shouldn't have to notice).
4. **Transparent**: log the detected crop, original → cropped dimensions, and bitrate target adjustment.
5. **Previewable**: `--crop-detect-only` reports detection per file without encoding anything.

### Technical requirements
1. Detection uses many sample windows spread over the file, not three points.
2. Result is the **union (most conservative) bounding box** of active picture across all windows.
3. Crop values are even (chroma-safe) and within frame bounds; validated before use.
4. Crop is applied identically to samples, all full-encode passes, and any detection-derived bitrate math.
5. Works with the existing audio/subtitle mapping unchanged (crop only touches video).

## Design

### Detection: `detect_black_bars(video_file, duration, width, height)`

Returns `W:H:X:Y` on stdout, or empty string (and return 0) when no crop should be applied.

**Sampling.** `CROP_SAMPLE_WINDOWS` (default 12) windows evenly spaced between 5% and 95% of duration, each `CROP_SAMPLE_SECONDS` (default 3) long. Skipping the first/last 5% avoids fade-in/out and studio logos. For videos shorter than `windows × seconds`, scan the whole file. One ffmpeg invocation per window using input seeking (`-ss` before `-i`), consistent with `transcode_sample()`.

```bash
ffmpeg -hide_banner -ss "$t" -i "$video" -t 3 -an -sn \
    -vf "cropdetect=limit=<CROP_LIMIT/255>:round=2:reset=0" -f null - 2>&1
```

The limit is a fraction of full scale so it scales with the source bit depth (see [Tuning results](#tuning-results)).

**Parsing (`parse_cropdetect_output`).** With `reset=0`, `cropdetect` reports a *cumulative* bounding box, so take the **last** well-formed `crop=W:H:X:Y` line of each window (not every line, not the mode). Ignore windows that produced no such line.

**Combining windows.** Convert each window's `W:H:X:Y` to edges (`x1=X`, `x2=X+W`, `y1=Y`, `y2=Y+H`), then take `min(x1)`, `max(x2)`, `min(y1)`, `max(y2)` across windows. This is the union: any window with real content near an edge pulls the crop back. This is also what protects against **dark scenes** (a fully dark window reports an over-aggressive crop, but the union with any brighter window corrects it).

**Consistency check.** IMAX/variable-aspect films legitimately differ between scenes, and the union handles that correctly, so windows are not required to agree. Instead, flag *suspicious* detections: if more than 25% of windows report a box materially smaller (> `CROP_OUTLIER_PX` per edge, default 16) than the union, log a warning with the per-window spread. This indicates a dark-heavy file or varying aspect; the union is still used.

**Minimum benefit.** `removed_pct = 1 - (W*H)/(width*height)`. If below `CROP_MIN_REMOVED_PCT`, return empty ("no significant bars").

**Safety bounds.** Reject (return empty with a warning) if W or H is odd, less than 16, less than 50% of the source dimension (almost certainly a bad detection), or if `X+W > width` / `Y+H > height`.

**Orientation/metadata.** ffmpeg autorotates before filters, so `cropdetect` and `crop` both operate on the displayed-orientation frame; take `width`/`height` from the same orientation used for the check. Rotation-tagged files are rare in this library, so v1 skips detection with a warning when rotation metadata is present. Anamorphic (SAR ≠ 1) is unaffected because crop works in stored pixels.

### Burned-in subtitles in the bars

1. Because `cropdetect` finds the extent of *non-black* pixels, burned-in subtitles that appear in any sampled window already enlarge the detected box and therefore *reduce* the crop. The union rule is the primary defense; no separate subtitle-zone check is built.
2. The residual risk is subtitles that appear only in unsampled time ranges. If real files show this, the mitigation is a secondary whole-file keyframe scan (`-skip_frame nokey`, hardware decode, `cropdetect`), which is fast and gives dense coverage (Open Decision 4).
3. The residual risk is documented in the README: auto-crop can clip burned-in subtitles that appear only in the bars and only outside sampled windows. Originals are preserved.

### Target bitrate and resolution tier

Define **effective resolution** once, shared with the existing "Aspect ratio corner case handling" item in `PLAN.md`:

- **Tier selection** uses the *original* (pre-crop) frame so a 1080p file stays in the 1080p tier. This also keeps behavior predictable: `--auto-crop` never moves a file to a different tier.
- **No bitrate scaling (decided)**: the target is exactly what it would be without cropping: the tier default for the *pre-crop* resolution, or the `--target-bitrate` value. Cropping only changes which pixels receive those bits.
- `--target-bitrate` is used verbatim, as today.
- **Below-target sources (default tiers only)**: re-encoding a source whose bitrate is below the tier target at the full tier target would inflate it. When a crop is active, no `--target-bitrate` was given, and the source bitrate is below the tier target, use the source bitrate as the target. This reuses the existing precedent in `transcode_video()` for incompatible-codec re-encodes (target = source bitrate). It is a ceiling, not a reduction of the default; an explicit `--target-bitrate` is never capped. Log when it applies.

The target (including the below-target rule) must be assigned **before** `LOWER_BOUND`/`UPPER_BOUND` are computed in `transcode_video()`.

### Where it hooks into `transcode_video()`

Only when `AUTO_CROP=1`:

1. Probe width/height/duration.
2. `detect_black_bars` → sets `CROP_PARAMS` (`W:H:X:Y`) or leaves it empty.
3. `calculate_target_bitrate` with the *original* height, then apply the below-target rule if a crop is active and no `--target-bitrate` override.
4. Compute `LOWER_BOUND`/`UPPER_BOUND`.
5. If crop is active: **bypass both short-circuit blocks** (within tolerance / below target) and log that the file is being re-encoded to apply a crop. Otherwise the existing logic runs untouched.
6. Everything downstream (`find_optimal_quality` → `transcode_sample`, `transcode_full_video` ×3) reads `CROP_PARAMS`.
7. `CROP_PARAMS` is reset at the start of every `transcode_video()` call (globals leak between files in the batch loop otherwise).

### Filter placement in FFmpeg commands

`transcode_sample()` and `transcode_full_video()` gain `-vf "crop=W:H:X:Y"` placed before encoding (no scale filter is involved today, so the filter chain is just the crop). It is built as an array following the existing `map_args` pattern, so the empty case adds nothing and existing behavior and tests are untouched. Neither function's positional signature changes; they read the global.

### Preprocessing interaction

In `preprocess_non_quicklook_files()` (and `handle_non_quicklook_at_target()`), when `AUTO_CROP=1`: run detection for each candidate; if a crop is detected, **skip the remux** and `continue`, leaving the original for the main pass. Detection is recomputed in the main pass rather than cached (bash 3.2 on macOS has no associative arrays; the ~2-5 s cost is acceptable for an opt-in feature).

## CLI surface

Flags on `boiler.sh` itself, not subcommands:

```
--auto-crop            Detect and remove black bars while transcoding
--crop-detect-only     Report detected crop per file; do not encode or modify anything
```

Tuning env vars (for testing and threshold tuning; not documented as stable user API): `CROP_SAMPLE_WINDOWS`, `CROP_SAMPLE_SECONDS`, `CROP_MIN_REMOVED_PCT`, `CROP_LIMIT` (cropdetect black threshold on an 8-bit 0-255 scale, default 24), `CROP_OUTLIER_PX`, `CROP_DEBUG` (1 = trace each window and the union).

`--crop-detect-only` implies `--auto-crop`, does not call `preprocess_non_quicklook_files` (which mutates files), and prints per file:

```
[INFO] song.mkv: 1920x1080 -> 1920x800 (crop=1920:800:0:140), removes 25.9% of frame
[INFO] other.mp4: no significant bars
```

**Why not subcommands first.** Gating on `plans/to-do/SUBCOMMAND-INTERFACE-PLAN.md` would have made an unimplemented, high-risk plan a dependency. A detect-only flag provides the same safe-preview workflow without it. When subcommands land, `detect-crop` becomes a thin wrapper over `detect_black_bars()`.

## Implementation Phases

### Phase 1: Detection (standalone functions + detect-only flag)
- [x] `get_video_dimensions()` (width, height)
- [x] `parse_cropdetect_output()` (last `crop=` line of a window)
- [x] `detect_black_bars()` with window sampling, union, sanity bounds, outlier warning
- [x] `--auto-crop` / `--crop-detect-only` parsing and `show_usage()` text
- [x] Tests for parsing, union math, bounds rejection (pure functions, no ffmpeg)
- [x] Generated fixtures for detection tests (see Testing)
- [x] Fix `bc` "Parse error: bad expression" seen on a real file (see [Lessons](#lessons-from-real-file-testing))
  - [x] Make `parse_cropdetect_output()` strict and reject boxes that are not `W:H:X:Y` numerics
  - [x] Guard `bc` inputs against empty or non-numeric values; warn with the offending value instead of silently returning 0.0
  - [x] Add `CROP_DEBUG=1`
  - [x] Regression tests in `tests/test_auto_crop.bats` and `test_boiler.sh`
- [x] Tune defaults against real files; record chosen thresholds in this doc (see [Tuning results](#tuning-results))
- [ ] Audit the other `ffprobe -of csv` parsers for the stray-separator problem (see [Lessons](#lessons-from-real-file-testing)); only the dimensions parser was in the crop path, index/codec parsing in `boiler.sh` and width/height parsing in `remux-select-audio.sh` were not checked

**Deliverable**: `boiler.sh --crop-detect-only` reports correct crops on fixtures and real files, modifies nothing.

### Phase 2: Encode integration
- [x] `CROP_PARAMS` global, reset per file
- [x] `-vf` array in `transcode_sample()` and `transcode_full_video()`
- [x] Reorder `transcode_video()` per [Where it hooks in](#where-it-hooks-into-transcode_video), including bypass of both short-circuits
- [x] Below-target source rule (default tiers only; override never capped)
- [x] Preprocess interaction (skip remux when crop detected)
- [x] Verify output dimensions with `ffprobe` after encode (fail the file if they differ from the expected cropped size)

**Deliverable**: `boiler.sh --auto-crop` produces cropped, bitrate-targeted output end to end.

### Phase 3: Documentation
- [x] README: flags, behavior, limitations (re-encode implied, `.orig.`/`.fmpg.` files not re-processed, residual burned-subtitle risk)
- [x] `docs/TECHNICAL.md`: algorithm (windows, union, unchanged target), `docs/ARCHITECTURE.md`: new functions
- [x] `PROJECT-CONTEXT.md`: new flags/globals; `PLAN.md`: status, reconcile with aspect-ratio item
- [ ] Move this plan to `plans/completed/` (after manual verification)

## Testing Strategy

Required before any commit: `bash test_boiler.sh` exits 0 with `Failed: 0`, plus the bats suite.

### Fixtures: generate, don't hand-collect
Small synthetic clips are created in test setup via `ffmpeg lavfi` (a few seconds each), so tests are deterministic and need no binaries in `testdata/`. They cover letterbox, pillarbox, full frame, tiny bars, dark-then-bright, varying aspect, burned-in text in a bar, a short clip, and a 10-bit letterbox. Odd or out-of-bounds boxes are tested by feeding `cropdetect`-style output to the pure functions. See `tests/test_auto_crop.bats`.

### Lessons from real-file testing

Synthetic 8-bit fixtures and mocked suites passed while real files failed. Three causes to remember when adding probe or filter logic:

- **ffprobe CSV is not stable.** For streams that carry side data (e.g. a Dolby Vision configuration record) the CSV writer appends a stray separator, so a frame size came back as `3840 2160x`. That reached `bc` as a parse error and silently became a `0.0%` result. Parse `key=value` output instead. Both suites mock `get_video_dimensions()`, so only tests that source a fresh `boiler.sh` exercise the real function.
- **`cropdetect` limits depend on bit depth** (see [Tuning results](#tuning-results)), so fixtures need a 10-bit case.
- **`find -iname` treats the pattern as a glob.** Filenames containing `[`, `]` or a backslash never matched their own encoded copy and were re-encoded every run. This predates the crop work and also affected `cleanup-originals.sh`.

### Unit tests (pure, mocked)
- [x] `parse_cropdetect_output()` last-line selection, no-line case, malformed lines
- [x] Window union math and outlier warning trigger
- [x] Sanity bounds (odd, tiny, <50%, overflow)
- [x] Target unchanged by crop; below-target rule; override verbatim
- [x] Empty crop ⇒ ffmpeg args unchanged
- [x] Cropped sample/full encode dimensions, short-circuit bypass, tier stays pre-crop

### Integration tests
- [x] `--crop-detect-only` prints expected lines and leaves files untouched (no renames, no temp files)
- [x] `--auto-crop` end to end on a fixture: output dimensions match crop; `.fmpg.` name carries measured bitrate
- [x] File within tolerance with bars + `--auto-crop` is re-encoded, not renamed `.orig.`
- [x] mkv within tolerance with bars + `--auto-crop` is not remuxed by preprocess
- [x] Batch of two files: crop state does not leak from file 1 to file 2
- [x] Without `--auto-crop`, all existing tests pass unchanged
- [x] Crop tests mirrored in legacy `test_boiler.sh`, and legacy suite brought to parity with all bats files

### Manual verification
- [ ] A real 2.39:1 1080p and a real 4K letterboxed file, compare `--crop-detect-only` output to a visual check
- [ ] A real file with burned-in subtitles in the bars
- [ ] A long, dark-heavy film for false-positive behavior
- [ ] Time `--crop-detect-only` on a 2 h file; confirm cost is acceptable (target: under ~15 s). Measured so far: see [Tuning results](#tuning-results)

## Research: cost of black bars and lossless cropping

Web research. Sources are mostly 2009-2020 forum threads (Doom9, VideoHelp) and ffmpeg-devel patches, not controlled benchmarks, and the size findings are about software x264, not `hevc_videotoolbox`. Treat as directional.

### How much file size do black bars cause?

- **Very little at constant quality.** One x264 CRF test of DVD footage found under 0.2% size difference between the full 720x480 frame and the cropped 720x368 frame ([VideoHelp](https://forum.videohelp.com/showthread.php?p=2168887)).
- **Why:** clean black blocks compress to almost nothing. The cost is concentrated in the edge between bars and picture, and is negligible when that edge is sharp and 16-pixel aligned ([Doom9](https://forum.doom9.org/archive/index.php/t-175094.html)).
- **Exceptions:** noisy bars (e.g. VHS captures), bars that are not clean black (compression noise in a real letterboxed clip made `CROP_LIMIT=8` miss them), and edges not on 16-pixel boundaries.
- **Other cropping benefits** noted by an x264 developer: saves encode/decode time and slightly improves motion-compensation efficiency ([Doom9](https://forum.doom9.org/showthread.php?p=1336260)).
- **At matched bitrate, size is the same** (size = bitrate x duration) ([VideoHelp](https://forum.videohelp.com/showthread.php?p=2362957)). Large size gaps in forum comparisons came from encodes at different bitrates.

### Consequences for boiler

- Output size is expected to be about the same with or without `--auto-crop`, consistent with the decision not to scale the target bitrate.
- Because bars already receive almost no bits, cropping does **not** meaningfully raise bits per visible pixel. The remaining benefits are playback (no bars, correct aspect ratio), decode work, and the noisy/misaligned-bar cases.
- Any bit-allocation benefit exists only when re-encoding with the crop; a metadata-only crop leaves the encoded stream untouched.
- **Open check:** none of the sources cover `hevc_videotoolbox`; hardware encoders are often less efficient than x264, so bars could cost more than the x264 figure. A same-`-q:v` encode of a letterboxed clip with and without `crop=` would settle it (not run).

### Lossless (metadata) cropping without re-encoding

- A true pixel crop needs a re-encode; forum consensus agrees.
- ffmpeg's `h264_metadata` / `hevc_metadata` filters can set the stream's cropping rectangle (`crop_left/right/top/bottom`), replacing any existing cropping; some values cannot be represented with subsampled chroma ([ffmpeg-devel](https://ffmpeg.org/pipermail/ffmpeg-devel/2017-October/218005.html)).
- **Player support is unreliable:** a [VLC bug report](https://code.videolan.org/videolan/vlc/-/issues/27382) found left/top crop not applied properly (Windows Media Player handled it); a [VideoHelp thread](https://forum.videohelp.com/showthread.php?p=2760287) reported `crop_left` failing for any nonzero value and a file VirtualDub2 would not open; a [Plex report](https://forum.videohelp.com/showthread.php?p=2514285) saw only the bottom crop applied (reply not seen). Symmetric letterbox bars need top and bottom, so a bottom-only result leaves half the bars visible.
- **mkvmerge / Matroska crop fields:** older threads describe poor, inconsistent support ([Doom9](https://forum.doom9.org/archive/index.php/t-163897.html)), and boiler outputs MP4 for QuickLook.
- **MP4Box:** threads show lossless aspect-ratio changes but no cropping; no current source found.
- **Net:** no tool found that crops reliably without re-encoding. Test any metadata crop on the actual playback targets (QuickTime, TV) before building an option.

## Tuning results

Measured with `detect_black_bars()` on real clips: a letterboxed 1080p clip (25 s), a letterboxed 3640x2048 clip (11 s), a roughly one-hour 4K 10-bit HEVC file, and the 2-minute 1080p/4K clips in `testdata/videos/` (no bars). Defaults are unchanged: `CROP_LIMIT=24`, 12 windows x 3 s, `CROP_MIN_REMOVED_PCT=3`.

**`CROP_LIMIT` (cropdetect black threshold), letterboxed 1080p clip, true crop 1920:808:0:136**

| limit | result | verdict |
|---|---|---|
| 8 | no bars found (compression noise in the bars exceeds the threshold) | too strict |
| 16 | `1920:812:0:134` (4 px less than ideal) | safe, slightly conservative |
| 24 | `1920:808:0:136` | **chosen** |
| 32 | `1920:808:0:136` | same as 24 |
| 48 | `1642:808:278:136` (cuts 278 px off the left side) | unsafe |

24 sits on a plateau (24-32) with margin on both sides; 48 shows how a high threshold eats real picture.

**Bit depth.** `cropdetect` compares an integer `limit` against raw samples at the source's native bit depth. 24 is above 8-bit limited-range black (16) but *below* 10-bit black (64), so a 10-bit letterboxed file with pure-black bars was reported as full frame and re-encoded with the bars intact. `limit=64` or higher found them. Fix: pass the limit as a fraction of full scale (`CROP_LIMIT/255`, i.e. 0.094118), which ffmpeg normalises per pixel format. This matches the integer 24 on 8-bit (`1920:808:0:136`) and is correct on 10-bit (`3840:1632:0:264`). `CROP_LIMIT` keeps its 8-bit (0-255) meaning.

**Window cost** (software decode of h264 sources; window count drives time, not file length):

| windows x seconds | 1080p | 4K (h264) |
|---|---|---|
| 6 x 3 | 2.1 s | 4.2 s |
| 12 x 3 | 4.6 s | 9.2 s |
| 24 x 3 | 8.8 s | 17.8 s |
| 40 x 1 | 11.6 s | 23.4 s |

12 x 3 meets the "under ~15 s" target for 4K h264, and the roughly one-hour 4K 10-bit HEVC file took 10.1 s. Cost is dominated by per-window seeks, so a 2 h file should cost about the same; that length is not yet measured.

**Minimum removal (3%)**: bar files removed 24-25%, no-bars clips 0.0%. Nothing sits near the threshold, so the data neither supports nor argues against changing it.

**Not covered**: window count and minimum removal have no real file that stresses them. Dark-heavy films, burned-in subtitles in bars and varying-aspect content still need the manual checks.

**Side finding**: the letterboxed 3640x2048 clip gets the 1080p tier (8 Mbps) because tier selection is by height (2048 < 2160). That is existing tier behavior unrelated to cropping; it belongs with PLAN.md's "Aspect ratio corner case handling".

## Open Decisions

| # | Decision | Status |
|---|---|---|
| 1 | Scale target bitrate by cropped area | **Resolved: no scaling** |
| 2 | Default `CROP_MIN_REMOVED_PCT` | **Resolved: 3%** |
| 3 | Window count/length | **Resolved: 12 × 3 s** (cost measured; miss rate unmeasured without stress files) |
| 4 | Build the whole-file keyframe scan? | **Open**: only if the pending burned-in-subtitle / dark-film checks show misses |
| 5 | Rotation-tagged files | **Resolved: skip detection with a warning in v1** |
| 6 | Crop vs remux; flag names; default; integration point; subcommand dependency | **Resolved**: crop always re-encodes (remux path bypassed when a crop applies); `--auto-crop` + `--crop-detect-only`; opt-in; per file inside `transcode_video()` with detection ahead of the short-circuits; no subcommand dependency |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Crop cuts real picture (dark scenes, varying aspect) | High | Union across 12 windows, 5% edge guard, 50% / min-size sanity bounds, outlier warning, opt-in |
| Burned-in subtitles in bars clipped | Medium | Union naturally preserves sampled subtitles; residual risk documented; optional whole-file keyframe scan |
| Tier drop shrinks bitrate unexpectedly | High | Tier from pre-crop height; target never scaled by crop |
| Re-encode inflates a low-bitrate source | Medium | Below-target rule: use source bitrate as target (default tiers only) |
| Short-circuit/preprocess paths silently skip the crop | High | Detection runs before them; covered by dedicated integration tests |
| Crop state leaks across files in a batch | Medium | Reset at start of `transcode_video()`; batch test |
| Bitrate prediction off because samples differ from final encode | Medium | Same `CROP_PARAMS` in samples and all passes |
| Detection time on long files | Low | Opt-in; fixed small window budget; measured |
| Output dims wrong (VideoToolbox/odd rounding) | Medium | Even-only `round=2`; post-encode `ffprobe` dimension check |
| Source-specific probe/filter behavior missed by 8-bit synthetic fixtures (bit depth, side data) | High | Real-file checks; 10-bit fixture; `key=value` ffprobe parsing; numeric input validation; `CROP_DEBUG=1` |

## Success Criteria

Automated tests cover each item below. The boxes stay unchecked until manual verification on real files is finished (one real-file run after the final fixes has been reported working).

- [ ] `--crop-detect-only` is accurate on fixtures and real files and modifies nothing
- [ ] `--auto-crop` produces correctly cropped, in-tolerance output
- [ ] Files within tolerance / below target with bars are re-encoded when `--auto-crop` is set, and untouched otherwise
- [ ] No tier change and no bitrate change from cropping; `--target-bitrate` used verbatim
- [ ] No false-positive crops on dark-scene and varying-aspect fixtures
- [ ] Without `--auto-crop`, behavior and tests are unchanged
- [ ] `bash test_boiler.sh` and bats suite pass; docs updated

## Future Enhancements (Out of Scope)

- **Lossless metadata crop**: for H.264/HEVC sources that need no other change, rewrite the SPS/VPS conformance window with `-bsf:v h264_metadata=crop_*` / `hevc_metadata=crop_*` (no re-encode, no size reduction; player support is unreliable, especially left/top, see [Research](#research-cost-of-black-bars-and-lossless-cropping) and verify on target players first). Would suit `remux-only.sh` better than `boiler.sh`.
- `detect-crop` / `preview-crop` subcommands once the subcommand interface exists (thin wrappers over `detect_black_bars()`); preview could export a single cropped PNG frame.
- Cache detection results per file for re-runs
- Whole-file batch detection pass before encoding
- Aspect-ratio standardization; content-aware (ML) detection

## References

- [FFmpeg cropdetect filter documentation](https://ffmpeg.org/ffmpeg-filters.html#cropdetect)
- [Stack Overflow: Auto-crop black bars](https://stackoverflow.com/questions/61084983/how-to-automatically-remove-black-bars-using-ffmpeg)
- [Super User: Is it possible to autocrop black borders](https://superuser.com/questions/772795/is-it-possible-to-autocrop-black-borders-of-a-video-with-ffmpeg)
- [Research: cost of black bars and lossless cropping](#research-cost-of-black-bars-and-lossless-cropping) for the sources behind the size and lossless-crop findings
- `PLAN.md` — "Aspect ratio corner case handling" (shares the effective-resolution definition)
- `plans/to-do/SUBCOMMAND-INTERFACE-PLAN.md`
