# Subtitle Preservation in boiler.sh

## Objective

Stop silently dropping subtitle streams during transcoding and remuxing. When a
source file contains subtitles, convert text-based streams to `mov_text` for the
MP4 output and warn the user about any image-based streams that must be dropped.

**Status**: Complete | **Priority**: High | **Effort**: Medium

---

## Background

`boiler.sh` maps only `-map 0:v:0` and `-map 0:a` in every ffmpeg invocation.
Subtitle streams are never mapped — they vanish silently with no warning.

The same problem existed in `remux-only.sh` and was fixed (see
`plans/completed/REMUX-SUBTITLE-MAPPING-BUG.md`). That fix established the
pattern this work should follow.

**MP4 subtitle constraints:**
- Text-based codecs (subrip/SRT, ASS, SSA, WebVTT) can be converted to
  `mov_text` for MP4 inclusion.
- Image-based codecs (hdmv_pgs_subtitle/PGS, dvd_subtitle, dvbsub) **cannot**
  be converted to text; they must be dropped with a warning.
- `mov_text` streams can be stream-copied into MP4 as-is.

---

## Scope

Three functions need changes:

| Function | Change needed |
|---|---|
| `remux_to_mp4()` | Same fix already applied to `remux-only.sh`: per-stream mapping of convertible streams only |
| `transcode_full_video()` | Add subtitle mapping: detect, filter, map convertibles, warn on drops |
| `transcode_sample()` | **No change** — samples are for quality estimation only, not final output |

---

## Design

### Two-stage subtitle loss

Subtitle loss in `boiler.sh` happens at **two distinct points**, not one:

1. **Preprocessing (`preprocess_non_quicklook_files`)** — `main()` calls this
   before the transcoding loop. For non-QuickLook formats (MKV, WMV, AVI, etc.),
   `remux_to_mp4()` is called here and the original is deleted on success. Any
   subtitle streams are dropped at this point, before transcoding begins.

2. **Transcoding (`transcode_full_video`)** — operates on the already-remuxed
   (subtitle-stripped) MP4. Even if subtitle mapping were added here, it would
   have nothing to map for files that went through preprocessing.

The remux step in preprocessing is therefore the higher-priority fix: it is where
subtitle data is permanently destroyed and the original removed.

### "Warn and continue" is not safe for a batch tool

A warning buried in the output of a long batch run is effectively silent. The
natural workflow pairs `boiler.sh` with `cleanup-originals.sh` — by the time the
user notices a warning, the originals are already gone. Image-based subtitles
(PGS, DVD) that cannot be converted to `mov_text` would be lost with no recovery
path.

`boiler.sh`'s existing design already provides an escape hatch: output files sit
alongside their originals until the user explicitly runs cleanup. A post-run
summary is sufficient signal — the original is still present for the user to act on.

### Decided behavior

- **Convertible streams** (subrip/SRT, ASS, SSA, WebVTT, mov_text): map and
  convert to `mov_text` automatically, no output.
- **Image-based streams** (PGS, DVD, dvbsub): drop silently per file.
- **All streams image-based** (output has zero subtitles, source had some):
  accumulate the filename; print a post-run summary listing all such files.
- **No subtitles in source**: proceed silently.

### Post-run accumulator

A `SUBTITLE_DROP_FILES` array in `main()` collects output filenames where all
subtitle streams were dropped (no convertible streams found). After the main loop,
if the array is non-empty, print a single summary block:

```
[WARN] The following output files have no subtitles; the source file(s) had
       image-based subtitle streams (PGS/DVD) that cannot be converted to MP4:
         my_video.fmpg.8.00.Mbps.mp4
         other_video.fmpg.5.00.Mbps.mp4
       Original files are preserved — use remux-select-audio.sh to keep
       image-based subtitles in MKV output.
```

`append_subtitle_map_args()` returns a status indicating whether any convertible
streams were found, so the caller can decide whether to add the file to the
accumulator.

### Code reuse

`remux-only.sh` already has `detect_subtitle_streams()` and
`is_subtitle_convertible()`. `boiler.sh` is a standalone script with no shared
library, so these functions must be duplicated or a shared helper extracted.

**Recommended approach**: Duplicate the two functions into `boiler.sh` for now.
They are small, stable, and tested. A shared library is a larger refactor that
can be its own future item.

### Subtitle map helper

Extract a small helper used by both `remux_to_mp4()` and
`transcode_full_video()` to avoid repeating the detect-and-filter loop:

```bash
# Append -map and -c:s mov_text args to an existing ffmpeg args array for
# convertible subtitle streams only. Silently drops image-based streams.
# Arguments: input_file, ffmpeg_args_array_name (nameref)
# Returns: 0 if at least one convertible stream was mapped, 1 if none
#          (caller uses return value to decide whether to add file to accumulator)
append_subtitle_map_args() { ... }
```

Callers check the return value: if `1` (no convertible streams found) AND the
source had at least one subtitle stream, they append the output filename to
`SUBTITLE_DROP_FILES`.

---

## Tasks

### Phase 1: Baseline

- [x] 1. Run full test suite (`bash test_boiler.sh` + `bats --jobs 8 tests/*.bats`)
  and confirm all green.

### Phase 2: Write failing tests (red)

- [x] 2. In `tests/test_subtitle_detection.bats` (or a new
  `tests/test_boiler_subtitles.bats`), add tests for `remux_to_mp4` in
  `boiler.sh`:
  - Mixed subtitles: only convertible stream is mapped by global index; `0:s?`
    absent; `mov_text` present; return value is 0.
  - All-incompatible subtitles: no subtitle map, no `mov_text`, return value is 1.

- [x] 3. Add tests for `transcode_full_video()` in `boiler.sh`:
  - File with one subrip stream: `-map 0:GLOBAL_IDX` and `-c:s mov_text` present
    in ffmpeg args.
  - File with only PGS stream: no subtitle map, no `mov_text`.
  - File with no subtitle streams: no subtitle-related args.

- [x] 4. Add tests for the post-run accumulator in `main()`:
  - When `append_subtitle_map_args` returns 1 for a file that had subtitle
    streams, the output filename appears in the post-run summary.
  - When all subtitles are convertible, no summary is printed.
  - When no files have any subtitles, no summary is printed.

- [x] 5. Run tests to confirm new tests fail (red).

### Phase 3: Implement (green)

- [x] 6. Copy `detect_subtitle_streams()` and `is_subtitle_convertible()` from
  `remux-only.sh` into `boiler.sh`. These are already tested in
  `tests/test_subtitle_detection.bats` via `remux-only.sh`; no new tests needed
  for the copies themselves.

- [x] 7. Add `append_subtitle_map_args()` helper to `boiler.sh`. Returns 0 if at
  least one convertible stream was mapped, 1 if none.

- [x] 8. Update `remux_to_mp4()` in `boiler.sh`:
  - After the audio map, call `append_subtitle_map_args`.
  - Check return value; caller is responsible for accumulator logic.

- [x] 9. Update `transcode_full_video()` in `boiler.sh`:
  - After the audio map, call `append_subtitle_map_args`.
  - Check return value; caller (`transcode_video`) is responsible for accumulator
    logic.

- [x] 10. Add `SUBTITLE_DROP_FILES` accumulator array to `main()`. Both
  `preprocess_non_quicklook_files` (via `remux_to_mp4`) and `transcode_video`
  (via `transcode_full_video`) propagate the no-convertible-subs signal up to
  their callers; `main()` appends to the array when signalled.

- [x] 11. Add post-run summary block to `main()`: if `SUBTITLE_DROP_FILES` is
  non-empty after the loop, print the warning block listing affected output files
  and pointing the user to `remux-select-audio.sh`.

### Phase 4: Verify

- [x] 12. Run new tests — assert all green.
- [x] 13. Run full test suite — assert all pass, no regressions.
- [x] 14. Manual smoke test: transcode a file with mixed subtitle types; confirm
  text subs appear in output, post-run summary lists the file, original is still
  present, file plays correctly.

---

## Notes

- `transcode_sample()` intentionally excluded: it produces a temporary quality
  estimation clip, not a deliverable output. Adding subtitles there would slow
  down the optimization loop with no benefit.
- After this change, a file transcoded from MKV with SRT subtitles will produce
  an MP4 with a `mov_text` subtitle track visible in QuickLook and VLC.
- PGS/DVD subtitles are a hard technical limit of the MP4 container — there is
  no lossless path. The post-run summary tells the user so they can use
  `remux-select-audio.sh` (which preserves all subtitles in MKV output) if needed.
- The accumulator fires only when the output has zero subtitles and the source had
  some. Mixed results (some converted, some dropped) do not trigger it — the user
  retains subtitle coverage in the output.
