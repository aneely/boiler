# Plan: Fix optimization loop output verbosity

## Symptom

Running boiler.sh fills the terminal with stacked ffmpeg progress lines and verbose
optimization loop detail. User wants:
1. Media metadata shown for the full transcode (codec, resolution, duration, streams)
2. Samples show a single updating `frame=...` progress line (same behavior as full transcode)
3. Full transcode shows one constantly-updating `frame=...` progress line

## Diagnosis

### What ffmpeg flag combinations actually produce

| Flags | Metadata | Progress line |
|---|---|---|
| `-loglevel error -stats` (current, both functions) | no | yes, but stacks |
| `-loglevel error` | no | no |
| `-loglevel info -hide_banner` | yes | no |
| `-loglevel info -hide_banner -stats` | yes | yes, updating |

### Why progress lines stack

The stacking is caused by terminal line wrapping, not a TTY detection issue. ffmpeg 8.x
added an `elapsed=` field to its stats output, making the progress line long enough to
wrap in a narrow terminal. When `\r` fires, it only returns to the start of the last
wrapped segment — earlier segments stay on screen, creating the appearance of new lines.

Confirmed: expanding the terminal window to a sufficient width causes the progress line
to update in place correctly, with no stacking.

Each sample also finishes with a newline, so the next sample's progress starts on a new
terminal line. This is expected and acceptable — the stacking concern was the wrapping,
not the per-sample separation.

### Current flags (after partial fix already applied)

- `transcode_sample()` line 1055: `-loglevel error` — silent, no progress feedback
- `transcode_full_video()` line 1507: `-loglevel info -hide_banner -stats` — correct

## Remaining fix

Restore `-stats` to `transcode_sample()` so each sample shows the same single updating
progress line as the full transcode:

| Function | Current | New |
|---|---|---|
| `transcode_sample()` | `-loglevel error` | `-loglevel error -stats` |

## Testing

1. Run `bash test_boiler.sh` before and after — must be 318/318 both times
2. Manual run in a wide terminal: confirm each sample shows one updating progress line
3. Manual run: confirm metadata block appears before the full transcode
4. Manual run: confirm one updating progress line during the full transcode
