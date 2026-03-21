# QuickLook Audio Compatibility Plan: Ensure Audio Plays in macOS QuickLook

## Objective

Investigate and optionally enforce audio codec choices that guarantee playback in macOS QuickLook, beyond just being MP4-muxable.

**Status**: Planned | **Priority**: Medium | **Effort**: Low-Medium

## Research

### Background

The audio codec compatibility fix (see AUDIO-CODEC-COMPATIBILITY-PLAN.md) ensures audio codecs can be *muxed into MP4*. But MP4-muxable does not mean QuickLook-playable. A file can be a valid MP4 that QuickLook refuses to play audio from.

### QuickLook Audio Requirements

macOS QuickLook has stricter requirements than the MP4 container spec:

- **AAC**: Universally supported. The safe default.
- **MP3**: Supported in MP4 containers.
- **ALAC**: Supported (Apple's own lossless codec).
- **AC3 / EAC3**: Valid in MP4 but QuickLook may not play the audio. These are Dolby codecs common in MKV rips. The video plays but audio is silent.
- **FLAC**: Technically supported in MP4 (since newer FFmpeg versions), but QuickLook support is inconsistent across macOS versions.
- **Opus**: Valid in MP4 per spec, but QuickLook does not play it.
- **PCM variants**: May or may not play depending on bit depth and sample rate.

### The Gap

Current state after the audio codec compat fix:
- **Incompatible audio** (wmav2, vorbis, etc.) is re-encoded to AAC -- these now work in QuickLook.
- **MP4-compatible but not QuickLook-friendly** audio (AC3, EAC3, Opus, FLAC) is copied as-is -- video plays but audio may be silent in QuickLook.

### Affected Scripts

| Script | Current behavior | Potential impact |
|---|---|---|
| `boiler.sh` | Transcodes video + copies audio (or AAC if incompatible) | AC3/EAC3 sources would have silent QuickLook audio |
| `remux-only.sh` | Remuxes to MP4 + copies audio (or AAC if incompatible) | Same |
| `remux-select-audio.sh` | Remuxes with audio track selection, `-c copy` | Same |

### Design Questions

1. **Should we always re-encode to AAC for QuickLook?** This guarantees playback but loses quality for lossless sources (FLAC, ALAC) and adds processing time.
2. **Should this be opt-in?** A flag like `--quicklook-audio` or `--reencode-audio` that forces AAC. Default could remain copy-if-compatible.
3. **Is AC3 actually broken in QuickLook?** Needs testing across macOS versions. Some reports suggest it works in Ventura+ but not earlier.
4. **ALAC special case**: ALAC is Apple-native and QuickLook-supported. If we re-encode lossless, should we use ALAC instead of AAC to preserve quality?

### Suggested Approach

Add a tiered compatibility concept:
- **Tier 1 (current)**: MP4-muxable -- prevents container-level failures
- **Tier 2 (this plan)**: QuickLook-playable -- guarantees audio in QuickLook preview

Implementation could be a `--quicklook-audio` flag that upgrades the check from tier 1 to tier 2, re-encoding non-QuickLook audio to AAC.

## Tasks

- [ ] 1. Test AC3, EAC3, Opus, FLAC audio in MP4 on current macOS to confirm which actually play in QuickLook.
- [ ] 2. Decide on approach: always re-encode vs opt-in flag vs tiered.
- [ ] 3. Implement chosen approach across boiler.sh, remux-only.sh, remux-select-audio.sh.
- [ ] 4. Add tests.
- [ ] 5. Run full test suite and verify.
