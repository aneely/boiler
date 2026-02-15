# Changelog

All notable changes to this project are documented here. Dates are taken from git commit history.

---

## 2026-02-03

### Changed

- **Documentation reorganization**: PROJECT-CONTEXT.md condensed from 375 lines to ~105 lines, focusing on development workflow directives and essential context. Moved detailed algorithm documentation to new `docs/TECHNICAL.md` file (260 lines) covering quality optimization, multi-pass strategy, and design decisions. Added comprehensive inline documentation to 12 key functions in `boiler.sh` including `calculate_target_bitrate()`, `find_optimal_quality()`, `calculate_adjusted_quality()`, `calculate_interpolated_quality()`, and `transcode_video()`.

---

## 2026-02-03

### Added

- **Bats test suite and dual-suite strategy**: Added bats-core framework (`tests/*.bats`); project now has legacy suite (`test_boiler.sh`) for quick iteration and bats for thorough pre-commit verification. Both use file-based mocking; no FFmpeg/ffprobe required (CI/CD ready). See README for how to run.
- **CHANGELOG and documentation cleanup**: Introduced CHANGELOG.md as the single place for version history. Reduced overlap between README, PLAN, and PROJECT-CONTEXT per plans/Completed/CONTEXT-REFACTOR-PLAN.md: PROJECT-CONTEXT trimmed of session history and duplicate sections; PLAN shortened (defaults/helpers in README, implementation notes only); README links to CHANGELOG. CHANGELOG dates backfilled from git history.

---

## 2026-01-31

### Changed

- **Predictable file processing order**: File lists from `find_all_video_files()`, `find_skipped_video_files()`, and `preprocess_non_quicklook_files()` are now sorted alphabetically so processing order is consistent across runs.

### Fixed

- **Remuxed output location**: Remuxed files (preprocessing or at-target) are now written in the same directory as the source (e.g. `videos/movie.mkv` → `videos/movie.orig.{bitrate}.Mbps.mp4`). Ensures cleanup-originals correctly skips them and avoids accidental deletion when run in that directory.

---

## 2026-01-26

### Fixed

- **Oscillation detection and history tracking**: Corrected bug in optimization loop oscillation detection and history tracking.

---

## 2026-01-18

### Added

- **remux-only.sh**: Standalone script to remux non-QuickLook formats to MP4 with `.orig.{bitrate}.Mbps` naming. Supports `-L`/`--max-depth`, codec compatibility checks; processes mkv, wmv, avi, webm, flv when codec is MP4-compatible.

---

## 2026-01-15

### Added

- **Configurable subdirectory depth**: `-L`/`--max-depth` for boiler.sh (default 2, 0 = unlimited). Same depth option added to cleanup-originals.sh. `validate_depth()`, updated `show_usage()`.

---

## 2026-01-14

### Changed

- **Starting quality value**: Adjusted default from 52 to 60 for faster convergence.

---

## 2026-01-13

### Added

- **Third pass with linear interpolation**: When second pass bitrate is still outside tolerance, a third pass uses linear interpolation between first and second pass (quality, bitrate) to compute quality for target bitrate (`calculate_interpolated_quality()`), addressing overcorrection.

---

## 2026-01-11

### Added

- **Command-line target bitrate and help**: `--target-bitrate`/`-t`, `--help`. `parse_arguments()`, `validate_bitrate()`, `show_usage()`. Override applies to all files in a run.

---

## 2026-01-08

### Added

- **Preprocessing for non-QuickLook formats**: `preprocess_non_quicklook_files()` runs before main file discovery. Finds and remuxes mkv, wmv, avi, webm, flv (and `.orig.` files) that are within tolerance or below target; codec compatibility checked via `is_codec_mp4_compatible()`.
- **WMV / codec incompatibility handling**: Non-QuickLook files at or below target that cannot be remuxed (e.g. WMV3) are transcoded to HEVC at source bitrate for QuickLook compatibility. Extracted `get_video_codec()`, `handle_non_quicklook_at_target()`.

### Changed

- **Trash handling**: Hybrid approach for moving files to trash: prefer native `trash` command on macOS 15+, fall back to AppleScript.

---

## 2026-01-06

### Added

- **Subdirectory processing**: Discovery and processing one level deep; output files in same directory as source; `has_encoded_version()` checks same directory.
- **MKV remuxing for optimized files**: MKV files within tolerance or below target are remuxed to MP4 with QuickLook compatibility (no re-encode).
- **Second transcoding pass**: If first full-video pass bitrate is outside tolerance, automatically performs a second pass with adjusted quality.
- **Original/encoded file matching**: Skips both original and encoded when encoded version exists in the same directory.
- **720p / 480p resolution support**: Resolution-based target bitrates for 720p and 480p; high-priority test coverage.

### Changed

- **Interrupt handling**: Ctrl+C stops processing immediately.

---

## 2026-01-05

### Added

- **Function mocking and main() integration tests**: File-based call tracking to mock FFmpeg/ffprobe; integration tests for `main()`; refactored utility functions and test harness. Tests work without FFmpeg/ffprobe.

### Changed

- **Constant quality mode**: Switched from bitrate mode (`-b:v`) to constant quality (`-q:v`). Quality value 0–100 iteratively adjusted to hit target bitrate; reduces blocky artifacts.
- **Optimization loop**: Proportional adjustment (min step 1, max step 10) based on distance from target. Oscillation detection breaks cycles (e.g. 60 ↔ 61 ↔ 62). No iteration limit; loop runs until convergence or quality bounds.
- **Sample duration and adaptive sampling**: 60-second samples (was 15s). Adaptive count: 1 sample for &lt;120s, 2 for 120–179s, 3 for ≥180s (beginning ~10%, middle ~50%, end ~90%). Better starting point for optimization.
- **Tolerance**: Decreased from ±10% to ±5% for target bitrate.
- **Filename format**: Output filenames now include actual bitrate (e.g. `video.fmpg.10.25.Mbps.mp4`).
- **Code refactoring**: Refactored utility functions; added test harness.

### Fixed

- **Short-circuit logic**: Pre-check now includes source bitrate below target (not only within tolerance).

---

## 2026-01-04

### Added

- **Modularization**: Script refactored into focused functions (utility, configuration, transcoding, orchestration); main execution flow in `main()`.
- **Early exit check**: Skip transcoding when source video is already within target bitrate tolerance.
- **QuickLook compatibility**: `-movflags +faststart` for samples; `-movflags +faststart` and `-tag:v hvc1` for final output so macOS Finder QuickLook works.
- **Process group cleanup**: Cleanup on exit/interrupt (input seeking optimization).
- **Project documentation**: README, PLAN, PROJECT-CONTEXT (then CONTEXT.md), workflow directives, gitignore.

### Changed

- **VideoToolbox hardware acceleration**: Switched to VideoToolbox and bitrate-based optimization (later refined to constant quality mode).
- **Bitrate calculation**: Refactored bitrate calculation logic to eliminate duplication (shared `measure_bitrate()`-style flow; `sanitize_value()` for bc).

### Fixed

- **Critical bugs**: Values sanitized before `bc` to avoid parse errors; logging to stderr to avoid corrupting return values; proportional adjustment integer rounding; other fixes included in modularization.
