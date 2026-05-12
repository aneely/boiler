# remux-only.sh: Subtitle Mapping Bug Fix

## Objective

Fix a crash when remuxing files that contain a mix of text-based (subrip/SRT) and
image-based (hdmv_pgs_subtitle/PGS) subtitle streams with the "include" option.

**Status**: Planned | **Priority**: High | **Effort**: Low

---

## Bug Report

When running `./remux-only.sh -p` on a file with mixed subtitle types and selecting
option 1 ("Include subtitles"), ffmpeg errors:

```
[sost#0:3/mov_text @ ...] Subtitle encoding currently only possible from text to text or bitmap to bitmap
Error opening output file
```

The file was not remuxed.

---

## Root Cause

`remux_to_mp4` maps every subtitle stream unconditionally with `-map "0:s?"`, then
applies `-c:s mov_text` to all of them:

```bash
-map "0:s?" -c:s mov_text
```

FFmpeg cannot convert image-based subtitles (hdmv_pgs_subtitle, dvd_subtitle) from
bitmap to text format. When the file contains any such streams, ffmpeg aborts with:

```
Subtitle encoding currently only possible from text to text or bitmap to bitmap
```

The UI correctly identifies incompatible streams and promises "incompatible dropped",
but `remux_to_mp4` never acts on that information — it always maps everything.

---

## Fix

Replace the blanket `-map "0:s?"` / `-c:s mov_text` in `remux_to_mp4` with
per-stream explicit mapping of only convertible subtitle streams.

When `subtitle_mode = "include"`:
1. Call `detect_subtitle_streams` on the input file to get codec and stream index per stream
2. For each stream, check `is_subtitle_convertible` on its codec
3. Emit `-map "0:GLOBAL_IDX"` only for convertible streams
4. Add `-c:s mov_text` only if at least one convertible stream was mapped

Image-based streams are never mapped, so ffmpeg never attempts bitmap→text conversion.

To implement step 3 correctly, `detect_subtitle_streams` needs to expose the actual
global stream index from ffprobe (not a sequential counter) so the mapping targets the
right stream. This requires adding `stream=index` to the ffprobe query and threading
that value through to `remux_to_mp4`.

Output tuple change:
```
Old: display_idx|codec|lang          (display_idx is a sequential counter)
New: display_idx|codec|lang|global_idx  (global_idx comes from ffprobe stream=index)
```

`report_subtitles` and `prompt_subtitle_choice` read fields 1–3 and need no changes.
`remux_to_mp4` reads the new field 4 for the `-map` argument.

---

## Tasks

### Phase 1: Baseline

- [ ] 1. Run full test suite (`bash test_boiler.sh` + `bats --jobs 8 tests/*.bats`) and
  confirm all green before any changes.

### Phase 2: Write failing tests (red)

- [ ] 2. In `tests/test_remux_only.bats`, add a test that mocks `detect_subtitle_streams`
  to return mixed subrip + hdmv_pgs data, then calls `remux_to_mp4` with
  `subtitle_mode=include` and a mock ffmpeg that records its arguments. Assert:
  - Only subrip's global stream index appears in the ffmpeg `-map` args
  - hdmv_pgs's global stream index does NOT appear in the ffmpeg `-map` args
  - `-c:s mov_text` is present
  - `-map "0:s?"` is NOT present

- [ ] 3. Add a test for the all-incompatible case: mock `detect_subtitle_streams` to
  return only hdmv_pgs streams. Assert `-c:s mov_text` is absent and no subtitle maps
  are emitted.

- [ ] 4. Run tests to confirm new tests fail (red). Legacy suite should stay green
  (it doesn't test remux-only internals).

### Phase 3: Implement to pass tests (green)

- [ ] 5. Update `detect_subtitle_streams` in `remux-only.sh`:
  - Change ffprobe `show_entries` to include `stream=index`
  - Parse global_idx from field 1 of CSV output
  - Shift codec to field 2, lang to field 3
  - Emit `display_idx|codec|lang|global_idx` (4 fields)
  - Rename loop variable `sub_idx` → `display_idx` for clarity

- [ ] 6. Update `remux_to_mp4` in `remux-only.sh`:
  - Remove `[ "$subtitle_mode" = "include" ] && ffmpeg_args+=(-map "0:s?")`
  - Remove `[ "$subtitle_mode" = "include" ] && ffmpeg_args+=(-c:s mov_text)`
  - Add: when mode is "include", call `detect_subtitle_streams`, loop results,
    emit `-map "0:GLOBAL_IDX"` for each convertible stream, track `has_convertible`
  - Add `-c:s mov_text` only when `has_convertible=1`

### Phase 4: Verify

- [ ] 7. Run new tests — assert all green.
- [ ] 8. Run full test suite (`bash test_boiler.sh` + `bats --jobs 8 tests/*.bats`) —
  assert all pass, no regressions.
