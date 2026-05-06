# Plan: Subtitle Detection and Interactive Confirmation for remux-only.sh

## Problem

`remux_to_mp4()` uses explicit `-map 0:v:0` and `-map 0:a` flags without any `-map 0:s`,
so subtitle streams are silently dropped. If the user then removes the original, the subtitle
data is permanently lost.

## Goal

Detect subtitle streams before remuxing, report what would happen to them, and give the user
an interactive choice before proceeding.

---

## Items

### [1] Add `detect_subtitle_streams()` function
Use `ffprobe` to enumerate all subtitle streams in the input file, capturing stream index,
codec name, and language tag. Outputs a list of `index|codec|language` tuples (one per line),
or nothing if no subtitles exist.

### [2] Add `is_subtitle_convertible()` function
Classifies a subtitle codec as convertible to `mov_text` (text-based: `subrip`, `ass`, `ssa`,
`webvtt`, `mov_text`, `text`) vs. not convertible (image-based: `hdmv_pgs_subtitle`,
`dvd_subtitle`, `dvbsub`, `pgssub`). Unknown codecs treated as not convertible.

### [3] Add `report_subtitles()` function
Before any remux happens, prints each subtitle stream's index, codec, language, and whether
it can be converted. Example:

```
  Subtitle streams detected:
    [0:s:0] subrip (eng) — convertible to mov_text
    [0:s:1] hdmv_pgs_subtitle (eng) — NOT convertible (image-based, will be dropped)
```

### [4] Add interactive confirmation prompt
After the report, present a numbered menu. Menu adapts based on convertibility:

- *All convertible*:
  ```
  [1] Include subtitles (convert to mov_text)
  [2] Proceed without subtitles
  [3] Abort
  ```
- *Mixed or none convertible*:
  ```
  [1] Include subtitles (convertible kept, incompatible dropped)
  [2] Proceed without subtitles
  [3] Abort
  ```

### [5] ~~Non-interactive / TTY guard~~ — DROPPED
Follow existing codebase pattern: `read -r || true`, empty response = abort.
See `plans/to-do/non-interactive-tty-guard.md` for cross-script handling.

### [6] Modify `remux_to_mp4()` to accept a subtitle mode argument
Add a third parameter `subtitle_mode` (`"include"` or `"none"`). When `"include"`,
appends `-map 0:s? -c:s mov_text` to the ffmpeg args. When `"none"`, no subtitle mapping
(current behavior preserved).

### [7] Wire up `process_one_file()`
Before calling `remux_to_mp4()`, call detect → if subtitles found, report → prompt → get mode.
If user chooses abort, increment `skipped_count` and `continue`. If no subtitles detected,
proceed silently — no behavior change.

### [8] No separate handling for the `.mp4` re-mux path (Phase 2 in `main()`)
Phase 2 re-muxes non-QuickLook-compatible `.mp4` files. The same detect/report/confirm logic
applies there because it also routes through `remux_to_mp4()`. No separate handling needed.

---

## Out of Scope

- Transcoding subtitles to formats other than `mov_text`
- Adding a CLI flag to pre-confirm subtitle behavior (non-interactive override)
- Changes to `boiler.sh` or other helper scripts
