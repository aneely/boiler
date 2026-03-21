# Audio Codec Compatibility Plan: Re-encode Incompatible Audio for MP4 Output

## Objective

Add audio codec compatibility checking so that audio streams incompatible with the MP4 container are re-encoded to AAC instead of copied. Currently, `-c:a copy` is used unconditionally, which fails when the source has audio codecs not supported in MP4 (e.g., wmav2 in WMV files).

**Status**: Planned | **Priority**: High | **Effort**: Low-Medium

## Research

### The Bug

When transcoding a .wmv file with WMA audio (wmav2), FFmpeg fails with:
```
Could not find tag for codec wmav2 in stream #1, codec not currently supported in container
```

The video transcode succeeds (wmv3 → hevc), but `-c:a copy` tries to place wmav2 audio into the MP4 container, which is unsupported. FFmpeg writes 0 bytes and boiler continues through multiple passes without catching the failure.

### Affected Code Paths

Three functions use `-c:a copy` unconditionally:

| Function | Line | Context |
|---|---|---|
| `transcode_sample()` | ~974 | Sample transcoding during quality optimization |
| `transcode_full_video()` | ~1412 | Full video transcoding (all 3 passes) |
| `remux_to_mp4()` | ~716 | Remuxing non-QuickLook formats to MP4 |

### Existing Pattern

The codebase already has `is_codec_mp4_compatible()` for **video** codecs and `get_video_codec()` for detection. The fix follows the same pattern:

1. Add `get_audio_codec()` — query ffprobe for audio codec name
2. Add `is_audio_codec_mp4_compatible()` — allowlist/denylist check
3. In each affected function, check audio compatibility and switch to `-c:a aac` when incompatible

### Audio Codecs: MP4-Compatible vs Incompatible

**Compatible** (safe to copy into MP4):
- `aac`, `ac3`, `eac3` (E-AC3), `mp3`, `mp2`, `alac`, `flac`, `pcm_*` variants, `opus` (MP4 supports it but QuickLook may not play it)

**Incompatible** (must re-encode):
- `wmav1`, `wmav2` (WMA)
- `vorbis` (Ogg/WebM native; technically possible in MP4 but poorly supported)
- `wmalossless`, `wmapro`
- `adpcm_ms` (AVI-native ADPCM)
- `dts`, `truehd` (licensing/container issues in some MP4 muxers)

### Design Decisions

- **Re-encode target**: AAC — universally MP4-compatible, QuickLook-friendly, good quality at reasonable bitrates
- **AAC encoding**: Use FFmpeg's built-in AAC encoder (no external lib needed). Default bitrate is fine for general use.
- **Scope**: Only switch to `-c:a aac` when the audio codec is known-incompatible. Unknown codecs default to copy (matching the existing video codec pattern — let FFmpeg handle it).
- **Multiple audio streams**: When re-encoding, all audio streams get re-encoded (`-c:a aac` applies to all mapped audio streams). This is acceptable since if one stream's codec is incompatible, they're likely all the same codec in the source.
- **Logging**: When audio re-encoding is triggered, log a WARN so the user knows audio is being re-encoded (not just copied).

### Impact on `remux_to_mp4()`

`remux_to_mp4()` is a pure-copy function (no transcoding). If audio is incompatible, it should re-encode audio while still copying video (`-c:v copy -c:a aac`). This is still much faster than a full transcode since only audio is processed.

## Approach

Test-driven: write failing tests first, then implement code to pass them.

## Tasks

### Phase 1: Baseline
- [x] 1. Run full test suite (legacy + bats) to confirm green baseline before any changes.

### Phase 2: Write failing tests
- [x] 2. Add tests for `is_audio_codec_mp4_compatible()` — compatible codecs (aac, ac3, mp3), incompatible codecs (wmav2, vorbis, wmapro), and unknown codecs (default to compatible).
- [x] 3. Add tests for `get_audio_codec_arg()` — returns "copy" for compatible, "aac" for incompatible.
- [x] 4. Add integration tests verifying that `transcode_sample()`, `transcode_full_video()`, and `remux_to_mp4()` use the correct audio codec arg based on source audio.
- [x] 5. Run tests to confirm new tests fail (functions don't exist yet).

### Phase 3: Implement to pass tests
- [x] 6. Add `get_audio_codec()` function next to `get_video_codec()` (~line 576). Uses ffprobe to query `a:0` codec_name.
- [x] 7. Add `is_audio_codec_mp4_compatible()` function next to `is_codec_mp4_compatible()` (~line 574). Denylist approach: known-incompatible codecs return 1, everything else returns 0.
- [x] 8. Add helper function `get_audio_codec_arg()` that takes a file path, checks audio codec compatibility, and returns either `copy` or `aac`. Logs a WARN when re-encoding is needed. This centralizes the logic so all three call sites use the same check.
- [x] 9. Update `transcode_sample()` to use `get_audio_codec_arg()` instead of hardcoded `-c:a copy`.
- [x] 10. Update `transcode_full_video()` to use `get_audio_codec_arg()` instead of hardcoded `-c:a copy`.
- [x] 11. Update `remux_to_mp4()` to use `get_audio_codec_arg()` instead of hardcoded `-c:a copy`.

### Phase 4: Verify
- [x] 12. Run full test suite (legacy + bats) and verify all pass (299 legacy, 252 bats).

### Phase 5: Zero-byte / failed FFmpeg output detection (Issue 2)
- [x] 13. Write failing tests for ffmpeg exit code and output file size checks in `transcode_sample()`, `transcode_full_video()`, and `remux_to_mp4()` (12 tests).
- [x] 14. Implement exit code + file size checks after each ffmpeg call; fail early with clear error.
- [x] 15. Run full test suite and verify all pass (299 legacy, 264 bats).

### Phase 6: Align utility scripts
- [x] 16. Check `remux-only.sh`, `remux-select-audio.sh`, `cleanup-originals.sh` for hardcoded `-c:a copy` and apply audio codec compatibility fix where needed.
  - `remux-only.sh`: Added `get_audio_codec()`, `is_audio_codec_mp4_compatible()`, `get_audio_codec_arg()` and updated `-c:a copy` to use it.
  - `remux-select-audio.sh`: Same functions added; updated `-c copy` to split into `-c:v copy -c:a $audio_codec_arg -c:s copy` for MP4 output.
  - `cleanup-originals.sh`: No ffmpeg/remux calls — no changes needed.
- [x] 17. Run full test suite and verify all pass (299 legacy, 264 bats).
