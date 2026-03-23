# QuickLook Detect and Remux Plan

## Objective

Detect `.mp4` files that are not QuickLook-compatible and re-mux them to fix the issues. `remux_to_mp4()` already applies all three known fixes; this plan is about detection and wiring it into `remux-only.sh`.

**Status**: Ready to execute | **Blocked on**: User go-ahead

---

## Scope

- **Files checked**: `.mp4` only. Non-MP4 formats are already handled by `remux-only.sh`. `.mov` is natively QuickLook-compatible and excluded.
- **Files skipped**: `.mp4` files with boiler markers (`.fmpg.`, `.orig.`, `.hbrk.`) — these were produced by boiler tooling and are already QuickLook-compatible.

---

## Detection

Check two failure modes via `ffprobe` (fast, reliable):

1. **Wrong HEVC tag** — `hev1` instead of `hvc1`
2. **Incompatible audio codec** — AC3, EAC3, Opus, FLAC, or anything not in `is_audio_codec_mp4_compatible()`

**Faststart detection is deferred** — no clean ffprobe one-liner exists. Revisit after implementation if feasible.

---

## Behavior

- **Default on** — no flag required; `.mp4` files are checked automatically when `remux-only.sh` runs
- **Compatible files** — logged as `[INFO] file.mp4: already QuickLook-compatible, skipping`; not re-muxed
- **Incompatible files** — re-muxed using `remux_to_mp4()`, which applies all three fixes (HEVC tag, faststart, audio)
- **Naming**: follows existing `remux-only.sh` convention (`{base}.orig.{bitrate}.Mbps.mp4`); `.remux.` fallback applies if output filename already exists, so the original is never silently destroyed if the fix produces a bad output
- **Original file**: deleted only after successful re-mux (same as current behavior)

---

## Implementation Location

`remux-only.sh` — extend `process_files()` to check `.mp4` files in addition to non-QuickLook formats.

**Future revisit**: When helper scripts are consolidated as `boiler.sh` subcommands (see `SUBCOMMAND-INTERFACE-PLAN.md`), this feature should be wired into `boiler.sh` preprocessing as well.

---

## Tasks

- [ ] 1. Add `is_quicklook_compatible()` function to `remux-only.sh` — checks HEVC tag and audio codec via ffprobe
- [ ] 2. Extend `find_remux_files()` (or add a parallel `find_mp4_files()`) to discover `.mp4` files without boiler markers
- [ ] 3. Extend `process_files()` to check discovered `.mp4` files and re-mux if `is_quicklook_compatible()` returns false
- [ ] 4. Add logging for compatible files (`already QuickLook-compatible, skipping`)
- [ ] 5. Add bats tests in `tests/test_remux_only.bats`:
  - `.mp4` with wrong HEVC tag → re-muxed
  - `.mp4` with incompatible audio → re-muxed
  - `.mp4` already compatible → logged, skipped
  - `.mp4` with boiler markers → skipped without checking
  - Naming collision → falls back to `.remux.mp4`
- [ ] 6. Run full test suite and verify
- [ ] 7. Revisit faststart detection feasibility
- [ ] 8. Revisit when subcommand architecture is implemented
