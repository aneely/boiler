# Context: Video Transcoding Tool

## Overview

This project provides a simplified command-line interface for transcoding video files on macOS. The tool automatically determines optimal encoding settings to achieve target bitrates while maintaining quality, making video compression accessible without deep knowledge of FFmpeg parameters. Currently macOS-only, with potential for cross-platform support in the future.

## Development Workflow

**Important**: Before adding or modifying items in [PLAN.md](PLAN.md), please discuss the proposed changes with the project maintainer. Planning decisions should be made collaboratively through conversation rather than unilaterally updating the plan document.

### Implementation Approval Process

**When the user asks for suggestions or options:**
- Present the options and trade-offs clearly
- **Do NOT automatically implement changes** - wait for explicit approval
- Allow the user to discuss, ask questions, and choose which approach they prefer
- Only implement changes after the user explicitly requests them

**When the user asks informational questions (e.g., "Is there a way to...", "How would I...", "What would happen if..."):**
- **STRICTLY ONLY provide an explanation or answer** - do NOT implement anything
- **NEVER start making code changes** when asked informational questions
- Explain the approach, solution, or answer to their question
- Wait for explicit request like "implement this", "add this", "make this change" before making any code changes
- Questions are for learning and discussion, not automatic implementation
- If unsure whether a request is informational or an implementation request, treat it as informational and ask for clarification

This ensures the user maintains control over the development direction and can make informed decisions about which solutions best fit their needs.

### Testing Before Committing

**CRITICAL: MANDATORY TESTING REQUIREMENT**

**Before committing ANY changes, you MUST:**
1. **Run the test suite**: Execute `bash test_boiler.sh` and verify it completes successfully
2. **Verify exit code**: The test suite MUST exit with code 0 (all tests passing)
3. **Check test output**: Review the test summary to confirm all tests passed (e.g., "Passed: 212, Failed: 0")
4. **Fix any failures**: If ANY tests fail, you MUST fix the issues before committing
5. **NEVER commit without running tests**: Do not skip this step, even for minor changes

**This is a hard requirement - commits made without running tests are considered incomplete and should be amended.**

The test suite verifies:
- All utility functions work correctly
- No regressions were introduced
- Integration tests pass (main() function behavior)
- Mocked functions behave as expected

This ensures code quality and prevents regressions from being committed to the repository.

### Documentation Update Directive

**When the user asks to "update for the next session", "remember the current state", or similar requests to preserve project state:**

1. **Update PROJECT-CONTEXT.md** with:
   - Any new architectural changes or code organization
   - Recent improvements, bug fixes, or refactorings
   - New technical details, design decisions, or implementation notes
   - Any changes to dependencies, file structure, or core components

2. **Update PLAN.md** with:
   - Current status of implemented features
   - Any new known issues or limitations discovered
   - Recent changes to the roadmap or priorities
   - Updates to helper scripts or tooling

3. **Update README.md** with:
   - Any missing information about current features or usage
   - New troubleshooting information
   - Updates to code structure or architecture descriptions
   - Any user-facing changes that should be documented

The goal is to ensure that a new session can pick up exactly where the previous one left off, with full context about the current state of the project, recent changes, and any important implementation details.

## Current Implementation

### Architecture

The tool is implemented as a modular bash script (`boiler.sh`) organized into focused functions:

1. **Discovers video files** in the current working directory and subdirectories (one level deep) using `find_all_video_files()`, skipping already-encoded files
2. **Processes each video file** found (batch processing) via `main()` which calls `transcode_video()` for each file
3. **Analyzes video properties** (resolution, duration) using `ffprobe` for each file
4. **Determines target bitrate** based on resolution
5. **Checks if source is already optimized** - Short-circuits if source video is already within ±5% of target bitrate or below target (renames file to include bitrate if below target)
6. **Iteratively finds optimal quality setting** using constant quality mode (`-q:v`) by transcoding samples from multiple points and adjusting quality to hit target bitrate
7. **Transcodes the full video** using the optimal quality setting
8. **Performs second pass if needed** - If the first pass bitrate is outside tolerance, automatically performs a second transcoding pass with an adjusted quality value calculated using the same proportional adjustment algorithm
9. **Performs third pass with interpolation if needed** - If the second pass bitrate is still outside tolerance, automatically performs a third transcoding pass using linear interpolation between the first and second pass data points to calculate a more accurate quality value, addressing overcorrection issues

#### Code Organization

The script is modularized into the following function categories:

**Utility Functions:**
- `check_requirements()` - Validates that ffmpeg, ffprobe, and bc are installed
- `extract_original_filename()` - Extracts original filename from an encoded filename (handles `.fmpg.`, `.orig.`, `.hbrk.` markers)
- `has_original_file()` - Checks if an encoded file has its original file in the same directory
- `has_encoded_version()` - Checks if a potential original file has an encoded version in the same directory
- `should_skip_file()` - Determines if a file should be skipped based on filename markers or original/encoded relationship
- `find_all_video_files()` - Discovers all video files in current directory and subdirectories (one level deep), excluding already-encoded files
- `find_skipped_video_files()` - Finds all skipped video files (files with `.hbrk.`, `.fmpg.`, or `.orig.` markers) in current directory and subdirectories (one level deep)
- `find_video_file()` - Discovers first video file in current directory (for backward compatibility)
- `is_mkv_file()` - Checks if a file is MKV container format (case-insensitive, bash 3.2 compatible)
- `is_non_quicklook_format()` - Checks if a file is a non-QuickLook compatible format (mkv, wmv, avi, webm, flv)
- `is_codec_mp4_compatible()` - Checks if a video codec can be copied into MP4 container without transcoding
- `get_video_codec()` - Extracts video codec using ffprobe
- `get_video_resolution()` - Extracts video resolution using ffprobe
- `get_video_duration()` - Extracts video duration using ffprobe
- `sanitize_value()` - Sanitizes values for bc calculations (removes newlines, carriage returns, trims whitespace)
- `bps_to_mbps()` - Converts bitrate from bits per second to megabits per second (with 2 decimal places)
- `calculate_squared_distance()` - Calculates squared distance between a bitrate and target bitrate (used for oscillation detection)
- `parse_filename()` - Parses filename into base name and extension (sets global variables BASE_NAME and FILE_EXTENSION)
- `measure_bitrate()` - Generic function to measure bitrate from any video file (ffprobe first, file size fallback)
- `get_source_bitrate()` - Measures source video bitrate (wrapper around `measure_bitrate()`)
- `is_within_tolerance()` - Checks if a bitrate is within the acceptable tolerance range (±5%)

**Configuration Functions:**
- `calculate_target_bitrate()` - Determines target bitrate based on resolution
- `calculate_sample_points()` - Calculates sample points with adaptive logic: 3 samples for videos ≥180s, 2 samples for 120-179s, 1 sample for shorter videos. Uses 60-second samples (or full video for videos <60s)
- `parse_arguments()` - Parses command-line arguments (`--target-bitrate`/`-t`, `--max-depth`/`-L`, `--help`/`-h`)
- `validate_bitrate()` - Validates target bitrate override values (must be between 0.1 and 100 Mbps)
- `validate_depth()` - Validates directory depth values (must be non-negative integer)
- `show_usage()` - Displays usage information and command-line options

**Transcoding Functions:**
- `transcode_sample()` - Transcodes a single sample from a specific point using constant quality mode (`-q:v`)
- `measure_sample_bitrate()` - Measures actual bitrate from a sample file (wrapper around `measure_bitrate()`)
- `find_optimal_quality()` - Main optimization loop that iteratively finds optimal quality setting by adjusting `-q:v` to hit target bitrate
- `calculate_adjusted_quality()` - Calculates adjusted quality value based on actual vs target bitrate using proportional adjustment algorithm
- `calculate_interpolated_quality()` - Calculates quality value using linear interpolation between two known (quality, bitrate) points to address overcorrection in second pass
- `transcode_full_video()` - Transcodes the complete video with optimal quality setting
- `remux_to_mp4()` - Remuxes non-QuickLook compatible video files to MP4 with QuickLook compatibility (copies streams without transcoding, checks codec compatibility first)
- `remux_mkv_to_mp4()` - Backward compatibility alias for `remux_to_mp4()`
- `cleanup_samples()` - Removes temporary sample files

**Preprocessing Functions:**
- `preprocess_non_quicklook_files()` - Preprocessing pass that remuxes non-QuickLook compatible files (mkv, wmv, avi, webm, flv) that are within tolerance or below target, including `.orig.` files. Runs before main file discovery to catch files that should be remuxed before skip checks.
- `handle_non_quicklook_at_target()` - Handles non-QuickLook format files that are within tolerance or below target bitrate. Checks codec compatibility and either remuxes (if compatible) or transcodes (if incompatible) to ensure QuickLook compatibility.

**Main Orchestration:**
- `preprocess_non_quicklook_files()` - Preprocessing pass that remuxes eligible non-QuickLook files before main processing. Automatically transcodes files with incompatible codecs (e.g., WMV3) that are within tolerance or below target, preserving bitrate for QuickLook compatibility
- `transcode_video()` - Orchestrates transcoding workflow for a single video file (analysis, optimization, transcoding, second pass if needed, third pass with interpolation if needed). Accepts optional `target_bitrate_override_mbps` parameter to override resolution-based target bitrate (useful for compatibility transcoding at source bitrate)
- `main()` - Orchestrates batch processing: first runs preprocessing, then processes all video files found in current directory and subdirectories

**Signal Handling:**
- `cleanup_on_exit()` - Cleanup function registered with trap to kill process group and remove sample files on exit/interrupt
- `handle_interrupt()` - Signal handler for interrupts (Ctrl+C) that sets interrupt flag and triggers cleanup

**Logging Functions:**
- `info()`, `warn()`, `error()` - Color-coded output functions (output to stderr to avoid interfering with function return values)

### Core Components

#### Video Discovery
- Searches current directory and subdirectories (default: one level deep, configurable via `-L`/`--max-depth` flag) for common video formats: `mp4`, `mkv`, `avi`, `mov`, `m4v`, `webm`, `flv`, `wmv`
- Processes all matching video files found (batch processing)
- Configurable depth: Use `-L 0` for unlimited recursive search, or `-L N` for N levels deep (default: 2)
- **File skipping logic**: Uses `should_skip_file()` to determine which files to process:
  - Skips files that contain encoding markers (`.fmpg.`, `.orig.`, or `.hbrk.`) in their filename
  - Skips original files if an encoded version exists in the same directory (checked via `has_encoded_version()`)
  - Uses `extract_original_filename()` to reverse-engineer original filenames from encoded filenames
  - `find_all_video_files()` discovers processable files, while `find_skipped_video_files()` identifies skipped files for user feedback
- Output files are created in the same directory as their source files

#### Resolution Detection
- Uses `ffprobe` to extract video stream height
- Categorizes videos into resolution tiers:
  - **2160p (4K)**: ≥2160 pixels height
  - **1080p (Full HD)**: ≥1080 pixels height
  - **720p (HD)**: ≥720 pixels height
  - **480p (SD)**: ≥480 pixels height
  - **Below 480p**: Falls back to 480p settings

#### Bitrate Targeting
- **2160p videos**: Target 11 Mbps
- **1080p videos**: Target 8 Mbps
- **720p videos**: Target 5 Mbps
- **480p videos**: Target 2.5 Mbps
- Acceptable range: ±5% of target bitrate

#### Quality Optimization Algorithm

The script uses an iterative approach to find the optimal quality setting using constant quality mode:

1. **Pre-check**: Before starting optimization, checks if source video is already within ±5% of target bitrate OR if source bitrate is below target. If either condition is true, exits early with a message indicating no transcoding is needed.
2. **Initial quality**: Starts with quality value 60 (VideoToolbox `-q:v` scale: 0-100, higher = higher quality/bitrate)
3. **Multi-point sampling**: Creates 60-second samples from multiple points in the video:
   - **Videos ≥ 180 seconds**: 3 samples at beginning (~10%), middle (~50%), and end (~90%)
   - **Videos 120-179 seconds**: 2 samples at beginning and end (with 60s spacing)
   - **Videos 60-119 seconds**: 1 sample (entire video)
   - **Videos < 60 seconds**: 1 sample (entire video, using full video duration)
4. **Bitrate measurement**: Averages bitrates from all samples using `ffprobe` or file size calculation
5. **Proportional adjustment algorithm**: Adjusts quality value proportionally based on distance from target:
   - **Minimum step**: 1 (for fine-tuning when close to target)
   - **Maximum step**: 10 (for large corrections when far from target)
   - **When bitrate too low**: Calculates ratio = actual_bitrate / target_bitrate, then adjustment = min_step + (max_step - min_step) × (1 - ratio)
     - Example: If at 50% of target (ratio=0.5), adjustment ≈ 6; if at 90% (ratio=0.9), adjustment ≈ 2
   - **When bitrate too high**: Calculates ratio = actual_bitrate / target_bitrate, then adjustment = min_step + (max_step - min_step) × (ratio - 1), capped at 1.0
     - Example: If at 200% of target (ratio=2.0), adjustment = 10; if at 110% (ratio=1.1), adjustment ≈ 2
   - Quality value bounds: 0 (lowest quality/bitrate) to 100 (highest quality/bitrate)
   - This proportional approach converges faster than fixed step sizes, making larger adjustments when far from target and smaller adjustments when close
6. **Convergence**: Stops when actual bitrate is within ±5% of target
7. **Oscillation detection**: Detects when the algorithm is cycling between quality values (e.g., 60 ↔ 61 ↔ 62) and breaks the loop by selecting the quality value that produces bitrate closest to target. Handles both 2-value oscillations and 3-value cycles.
8. **No iteration limit**: Loop continues indefinitely until convergence, oscillation detection, or quality bounds are reached
9. **Second pass transcoding**: After the full video is transcoded with the optimal quality setting, if the resulting bitrate is outside the ±5% tolerance range, automatically performs a second transcoding pass. The second pass uses `calculate_adjusted_quality()` to compute an adjusted quality value based on the actual bitrate from the first pass, using the same proportional adjustment algorithm.
10. **Third pass with linear interpolation**: If the second pass bitrate is still outside tolerance, automatically performs a third transcoding pass using `calculate_interpolated_quality()`. This function uses linear interpolation between the two known data points (first pass: quality1 → bitrate1, second pass: quality2 → bitrate2) to calculate a more accurate quality value for the target bitrate. This addresses overcorrection issues where the proportional adjustment algorithm overcorrects due to the non-linear relationship between quality values and bitrates in VideoToolbox encoding. The interpolation formula: `quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)`. This ensures the final output gets as close to the target bitrate as possible, even if sample-based optimization and the second pass didn't perfectly predict the full video bitrate.

#### Encoding Settings

**Current defaults:**
- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (Apple VideoToolbox hardware acceleration)
- **Quality control**: Constant quality mode (`-q:v`) - Iteratively adjusts quality value (0-100, higher = higher quality/bitrate) to hit target bitrate
- **Container**: MP4
- **Audio**: Copy (no re-encoding)
- **Output naming**: 
  - **Transcoded files**: `{base}.fmpg.{actual_bitrate}.Mbps.{ext}` (e.g., `video.fmpg.10.25.Mbps.mp4`)
    - Actual bitrate is measured after transcoding and included in filename with 2 decimal places
  - **Files below target**: `{base}.orig.{actual_bitrate}.Mbps.{ext}` (e.g., `video.orig.2.90.Mbps.mp4`)
    - Files already below target bitrate are renamed to include their actual bitrate without transcoding
- **Platform**: Optimized for macOS Sequoia (hardware acceleration unlocked)
- **QuickLook compatibility**: Uses `-movflags +faststart` for sample transcoding; both `-movflags +faststart` and `-tag:v hvc1` for final output to ensure macOS Finder QuickLook support
- **Second pass transcoding**: If the first full video transcoding produces a bitrate outside the ±5% tolerance range, automatically performs a second transcoding pass with an adjusted quality value calculated using the same proportional adjustment algorithm.
- **Third pass with linear interpolation**: If the second pass bitrate is still outside tolerance, automatically performs a third transcoding pass using linear interpolation between the first and second pass data points to calculate a more accurate quality value. This addresses overcorrection issues and ensures the final output is as close to the target bitrate as possible.

### Dependencies

- **ffmpeg**: Video encoding/transcoding
- **ffprobe**: Video analysis and metadata extraction
- **bc**: Arbitrary precision calculator for bitrate calculations

### File Structure

```
boiler/
├── boiler.sh                    # Main transcoding script
├── test_boiler.sh               # Test suite with function mocking (212+ tests)
├── copy-1080p-test.sh          # Helper: Copy 1080p test video to current directory
├── copy-4k-test.sh              # Helper: Copy 4K test video to current directory
├── cleanup-mp4.sh               # Helper: Remove all .mp4 files from project root
├── cleanup-originals.sh          # Helper: Remove all .orig. marked video files (moves to trash). Supports -L/--max-depth flag.
├── remux-only.sh                # Helper: Remux video files to MP4 with .orig.{bitrate}.Mbps naming. Supports -L/--max-depth flag.
├── .gitignore                   # Git ignore patterns (macOS, video files, outputs)
├── PROJECT-CONTEXT.md           # Technical documentation
├── PLAN.md                      # Development roadmap
├── README.md                    # User documentation
├── testdata/                    # Test video files
│   ├── videos/
│   │   ├── 1080p/              # 1080p test videos (gitignored)
│   │   └── 4k/                  # 4K test videos (gitignored)
│   └── video-attribution-cc-license.txt
└── [transcoded output files]    # Generated in working directory (gitignored)
```

## Technical Details

### Bitrate Calculation Methods

The script uses two methods to determine bitrate:

1. **Primary**: `ffprobe` stream bitrate (most accurate)
2. **Fallback**: File size calculation: `(file_size_bytes * 8) / duration_seconds`

### Error Handling

- Uses `set -e` for strict error handling
- Validates required tools are installed
- Checks for video file existence
- Validates resolution detection
- Handles missing bitrate metadata gracefully
- All values passed to `bc` are sanitized (newlines and whitespace removed) to prevent parse errors
- Logging functions output to stderr to prevent interference with function return values

### Output Formatting

- Color-coded messages:
  - **Green**: Informational messages
  - **Yellow**: Warnings
  - **Red**: Errors
- Progress indicators for iterations and transcoding status
- All logging functions (`info()`, `warn()`, `error()`) output to stderr to ensure they don't interfere with function return values when captured via command substitution

## Recent Improvements

### Code Refactoring
- **Consolidated bitrate measurement**: Created generic `measure_bitrate()` function that eliminates duplicate code between `get_source_bitrate()` and `measure_sample_bitrate()`. Both functions now call the shared implementation.
- **Extracted tolerance checking**: Created `is_within_tolerance()` function to replace duplicate range checking logic in `main()` and `find_optimal_bitrate()`. Improves readability and maintainability.
- **Value sanitization helper**: Added `sanitize_value()` function for consistent sanitization of values before bc calculations. Used throughout the script for cleaner, more maintainable code.

### Testing Infrastructure

**Test Suite (`test_boiler.sh`):**
- **212+ tests** covering utility functions, mocked FFmpeg/ffprobe functions, and full `main()` integration (including second and third pass transcoding scenarios, multiple resolution support, `calculate_adjusted_quality()` and `calculate_interpolated_quality()` unit tests, codec compatibility checking, configurable depth traversal, command-line argument parsing, and error handling tests)
- **Function mocking approach**: Uses file-based call tracking to mock FFmpeg/ffprobe-dependent functions without requiring actual video files or FFmpeg installation
- **Mocked functions**:
  - `get_video_resolution()` - Returns configurable resolution (default: 1080p)
  - `get_video_duration()` - Returns configurable duration (default: 300s)
  - `measure_bitrate()` - Returns configurable bitrate (supports source, sample, and output file differentiation)
  - `transcode_sample()` - Tracks calls instead of transcoding
  - `transcode_full_video()` - Tracks calls instead of transcoding
  - `find_video_file()` - Returns test file paths
  - `check_requirements()` - Skips requirement checks in test mode
- **Call tracking**: Uses temporary files to track function calls across subshells (command substitution creates subshells where variable assignments don't persist)
- **Integration tests**: Tests `main()` function covering:
  - Early exit when source is within tolerance
  - Early exit when source is below target (with file renaming verification)
  - Full transcoding workflow (source above target)
- **Benefits**:
  - Fast execution (no actual transcoding)
  - No FFmpeg/ffprobe required (enables CI/CD in environments without FFmpeg)
  - Verifies function behavior through call tracking rather than file side effects
  - No external dependencies (no Python, dd, or other tools needed)

## Current Session Status

### Latest Session (Remuxed-but-Never-Transcoded Edge Case)

**Edge case:** Some files get remuxed (preprocessing or remux-only.sh) but are never transcoded (at/below target, so they only get remuxed with `.orig.` naming). If a remuxed file did not get the `.orig.` marker or was written to a different directory than the source, running cleanup-originals on that directory could delete the remuxed file because it has no transcoding markers and no companion transcoded file.

**Fix applied:**
- **boiler.sh**: `handle_non_quicklook_at_target()` now writes the remuxed output in the same directory as the source. Output path is built with `dirname "$video_file"` so that e.g. `videos/movie.mkv` becomes `videos/movie.orig.{bitrate}.Mbps.mp4` instead of `movie.orig.{bitrate}.Mbps.mp4` in the current working directory. Remuxed files therefore stay next to the original path and always carry the `.orig.` marker, so cleanup-originals correctly skips them.

**Documented in PLAN.md:**
- Future enhancement: "Remuxed-but-never-transcoded vs. cleanup-originals" with options to ensure all remuxed outputs use `.orig.` and same-dir paths, and optionally to have cleanup-originals only treat a file as "original" when an encoded/remuxed companion exists in the same directory.

### Previous Session (Remux-Only Script and Future Enhancements)

**Remux-Only Script:**
- Created `remux-only.sh` - Standalone script for remuxing video files to MP4 with `.orig.{bitrate}.Mbps` naming
- Only remuxes (no transcoding) - converts container format for QuickLook compatibility
- Processes non-QuickLook compatible formats: mkv, wmv, avi, webm, flv (only if codec is MP4-compatible)
- Includes configurable subdirectory depth traversal via `-L`/`--max-depth` flag (matching boiler.sh and cleanup-originals.sh)
- Checks codec compatibility before remuxing (skips incompatible codecs like WMV3)
- Measures source bitrate and includes it in the output filename
- Removes original file only if remux succeeds
- Supports processing specific files or all compatible files in directory/subdirectories

**Future Enhancements:**
- Added future enhancement to PLAN.md for force flag (`--force` or `-f`) to bypass file skipping logic in boiler.sh
- Force flag would allow re-processing files with `.fmpg.`, `.orig.`, or `.hbrk.` markers
- Documented use cases: re-encoding with updated settings, fixing encoding issues, updating encoding parameters

### Previous Session (Configurable Subdirectory Depth)

**Configurable Directory Traversal:**
- Added `-L` and `--max-depth` command-line flags to `boiler.sh` for configurable subdirectory depth traversal
- Default depth remains 2 (current directory + one subdirectory level) for backward compatibility
- Supports depth 0 for unlimited recursive search
- Updated `find_all_video_files()`, `find_skipped_video_files()`, and `preprocess_non_quicklook_files()` to use configurable depth
- Added `validate_depth()` function for input validation
- Updated `show_usage()` with depth flag documentation and examples
- Added comprehensive tests for depth functionality (validate_depth, parse_arguments with depth flags, find_all_video_files with various depths)
- Enhanced `cleanup-originals.sh` with the same configurable depth capability for consistency
- Total test count: 212+ tests (up from 188+)
- All tests passing

**Implementation Details:**
- Global variable `GLOBAL_MAX_DEPTH` with default value of 2 (allows environment variable override for testing)
- Depth validation ensures non-negative integers only
- Unlimited depth (0) removes `-maxdepth` constraint from find commands
- Helper scripts (`cleanup-originals.sh`) now support the same depth traversal capability

### Previous Session (Linear Interpolation for Third Pass)

**Third Pass with Linear Interpolation:**
- Added `calculate_interpolated_quality()` function that uses linear interpolation between two known data points to calculate a more accurate quality value
- Addresses overcorrection issue where the proportional adjustment algorithm in the second pass would overcorrect, causing the bitrate to swing from too high to too low (or vice versa)
- Implementation: When second pass bitrate is still outside tolerance, performs a third pass using interpolation between first pass (quality1 → bitrate1) and second pass (quality2 → bitrate2) to find the quality value that should produce the target bitrate
- Formula: `quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)`
- Handles edge cases: Bitrates too close (uses midpoint), clamps to valid range [0, 100]
- This ensures the final output gets as close to the target bitrate as possible, even when the quality-to-bitrate relationship is non-linear

**Implementation Details:**
- Added `calculate_interpolated_quality()` function (lines 1062-1100)
- Updated `transcode_video()` to store first pass data and perform third pass with interpolation when second pass is still out of tolerance
- Third pass uses actual data points instead of assuming linear relationship, providing more accurate quality adjustment

### Previous Session (Command-Line Target Bitrate Override)

**Command-Line Argument Support:**
- Added `--target-bitrate` (or `-t`) flag to override resolution-based target bitrate
- Accepts decimal values (e.g., `9.5` for 9.5 Mbps)
- Validates bitrate values (must be between 0.1 and 100 Mbps)
- Applies override to all files in batch processing
- Includes `--help` flag for usage information

**Implementation Details:**
- Added `parse_arguments()` function for command-line parsing
- Added `validate_bitrate()` helper function for input validation
- Added `show_usage()` function for help output
- Updated `main()` to call `parse_arguments()` and pass override to `transcode_video()`
- Updated `preprocess_non_quicklook_files()` to use global override when set
- Global variable `GLOBAL_TARGET_BITRATE_MBPS` stores the override value

**Testing:**
- Added tests for `validate_bitrate()` function (valid and invalid inputs)
- Added tests for `parse_arguments()` function (flags, error cases, multiple flags)
- Added integration tests for `main()` with override
- Added tests for `preprocess_non_quicklook_files()` with override
- Total test count: 188+ tests (up from 183)
- All tests passing

**Future Enhancement Path:**
- Code structure designed to easily extend to resolution-specific overrides (e.g., `-t 2160p=9,1080p=5`)
- Foundation laid for config file support (`--config bitrates.conf`)

### Previous Session (WMV Codec Incompatibility Handling)

**WMV Files with Incompatible Codecs:**
- Added handling for WMV files (and other non-QuickLook formats) that are within target bitrate tolerance or below target but cannot be remuxed due to codec incompatibility (e.g., WMV3)
- When remuxing fails due to codec incompatibility, the script now automatically transcodes the file to HEVC at the source bitrate (preserving file size while improving compatibility)
- This ensures QuickLook compatibility without inflating file size, leveraging HEVC's superior compression efficiency (HEVC can maintain similar quality at the same bitrate as older codecs like WMV3)
- Transcoding uses the `.orig.` naming pattern since the file is already at or below target bitrate
- Handled in both `preprocess_non_quicklook_files()` and `transcode_video()` for consistency

**Target Bitrate Override Support:**
- Modified `transcode_video()` to accept an optional `target_bitrate_override_mbps` parameter
- When provided, uses the override instead of calculating resolution-based target bitrate
- Enables transcoding to specific bitrates (e.g., source bitrate for compatibility transcoding)
- Sets up foundation for future command-line argument support (e.g., `--target-bitrate`)

**Testing:**
- Added tests for codec incompatibility handling in both preprocessing and main transcoding paths
- Added tests for target bitrate override functionality
- Total test count: 183 tests (up from 163)
- All tests passing

### Previous Session (Preprocessing and Codec Compatibility)

**Preprocessing Pass for Non-QuickLook Formats:**
- Added `preprocess_non_quicklook_files()` function that runs before main file discovery
- Finds and remuxes non-QuickLook compatible files (mkv, wmv, avi, webm, flv) that are within tolerance or below target
- Also processes `.orig.` files for nondestructive remuxing to MP4
- Ensures files that should be remuxed are handled before skip checks

**Codec Compatibility Checking:**
- Added `is_codec_mp4_compatible()` function to check if codecs can be copied into MP4
- Updated `remux_to_mp4()` to check codec compatibility before attempting remux
- Prevents remux failures with incompatible codecs (wmv3, wmv1, wmv2, vc1, rv40, rv30, theora)
- Provides clear warning messages when codecs are incompatible

**Testing:**
- Added 25 new tests covering `is_non_quicklook_format()`, `is_codec_mp4_compatible()`, and `remux_to_mp4()` with codec checking
- Total test count: 163 tests (up from 138)
- All tests passing

### Previous Session (Subdirectory Processing)

**Batch Processing with Subdirectory Support:**
- Modified `find_all_video_files()` to search subdirectories one level deep (`find . -maxdepth 2`)
- Updated `has_encoded_version()` to check for encoded versions in the same directory as the source file (not just current directory)
- Updated `find_skipped_video_files()` to search subdirectories one level deep
- Enhanced `main()` to show directory context in progress messages for files in subdirectories
- Output files are created in the same directory as their source files
- All existing tests pass (183 tests total)

### Previous Session (Testing Infrastructure)

**Function Mocking and Integration Tests:**
- Implemented file-based call tracking system for mocking FFmpeg/ffprobe functions
- Added 25 integration tests for `main()` function covering all code paths
- Refactored test suite to avoid file I/O dependencies (no Python, dd, or large file creation needed)
- Tests now work across subshells using temporary files for call tracking
- Total test coverage: 138 tests covering utility functions, mocked functions, and integration scenarios (including second pass transcoding, multiple resolution support, `calculate_adjusted_quality()` unit tests, and error handling tests)
- All tests passing and CI/CD ready (no FFmpeg/ffprobe required for testing)

**Key Technical Decisions:**
- Used file-based tracking instead of arrays/strings to work around bash subshell limitations (command substitution `$(...)` creates subshells where variable assignments don't persist)
- Mocked `find_optimal_quality()` initially but removed mock to allow full integration testing - optimization converges quickly when sample bitrates match target
- Tests verify function behavior through call tracking rather than file side effects, making them faster and more reliable

### Recent Major Changes (Current Implementation)

**Switched to Constant Quality Mode:**
- Changed from bitrate mode (`-b:v`) to constant quality mode (`-q:v`) to match HandBrake's approach
- Uses VideoToolbox's `-q:v` parameter (0-100 scale, higher = higher quality/bitrate)
- Iteratively adjusts quality value to hit target bitrate, similar to CRF/RF mode behavior
- This approach adapts bitrate to content complexity, reducing blocky artifacts

**Optimization Loop Improvements:**
- Removed iteration limit safeguard - loop continues until convergence or quality bounds reached
- Fixed quality adjustment logic to trend correctly:
  - Bitrate too low → increase quality value (trend upwards)
  - Bitrate too high → decrease quality value (trend downwards)
- **Proportional adjustment algorithm**: Replaced fixed step size (2) with proportional adjustment based on distance from target:
  - Minimum step: 1 (for fine-tuning when close to target)
  - Maximum step: 10 (for large corrections when far from target)
  - Adjustment scales proportionally: larger adjustments when far from target, smaller when close
  - Faster convergence: reduces iterations needed, especially when starting far from target bitrate
- **Oscillation detection**: Added detection for cycles between quality values (e.g., 60 ↔ 61 ↔ 62) that can occur with tight tolerances. When oscillation is detected, the algorithm selects the quality value that produces bitrate closest to target and breaks the loop, preventing infinite oscillation.
- Starting quality value: 60 (increased from 52 for faster convergence)

**Sample Duration Improvements:**
- Increased sample duration from 15 seconds to 60 seconds for better bitrate accuracy
- Added adaptive sampling logic for shorter videos:
  - Videos < 60 seconds: Uses entire video as single sample
  - Videos 60-119 seconds: Uses 1 sample (entire video)
  - Videos 120-179 seconds: Uses 2 samples (beginning and end with 60s spacing)
  - Videos ≥ 180 seconds: Uses 3 samples (10%, 50%, 90% positions)
- Longer samples average out more variation, improving bitrate targeting accuracy
- For longer videos, each iteration now samples 180 seconds total (3 × 60s)

**Filter Changes:**
- Removed deblocking filters - relying on constant quality mode to handle quality/artifacts

### Known Issues

- **FFmpeg processes not cleaned up on interrupt**: When using input seeking (`-ss` before `-i`), interrupting the script (Ctrl+C) leaves FFmpeg child processes running. Signal handling is implemented but may need verification.

### Future Enhancements (See PLAN.md)

- Configurable target bitrates per resolution
- SDR vs HDR bitrate differentiation
- Configurable constant quality start ranges
- **Border detection and cropping**: Enhance the main script to use border detection to automatically cut black bars (letterboxing/pillarboxing) out of reencoded files. This would improve file size efficiency by removing unnecessary black borders before transcoding, ensuring the encoded video only contains the actual content area. Implementation considerations:
  - Use FFmpeg's `cropdetect` filter to detect black borders automatically
  - Apply cropping filter during transcoding to remove detected borders
  - Preserve aspect ratio and ensure cropping doesn't affect video quality
  - Handle edge cases where border detection might incorrectly identify content as borders
  - Make cropping optional via command-line flag (e.g., `--crop-borders` or `-c`) to allow users to preserve original framing when desired

### Smart Pre-processing
- Added early exit check: If source video is already within ±5% of target bitrate OR if source bitrate is below target, the script exits immediately with a helpful message, avoiding unnecessary transcoding work
- Uses the same tolerance logic (±5%) and comparison method as the optimization loop for consistency
- `get_source_bitrate()` function measures source video bitrate using the same approach as sample measurement (ffprobe first, file size fallback)
- Handles both cases: videos already at target (within tolerance) and videos already more compressed than target (below target bitrate)
- **Automatic renaming for files below target**: When a source file is below target bitrate, it is automatically renamed to include its actual bitrate using the format `{base}.orig.{bitrate}.Mbps.{ext}` (e.g., `video.orig.2.90.Mbps.mp4`). This provides consistent filename formatting even for files that don't need transcoding.
- **Non-QuickLook format remuxing**: The script includes a preprocessing pass (`preprocess_non_quicklook_files()`) that runs before main file discovery. This pass:
  - Finds all non-QuickLook compatible formats (mkv, wmv, avi, webm, flv) that are within tolerance or below target
  - Also processes `.orig.` files (nondestructive remuxing for QuickLook compatibility)
  - Remuxes eligible files to MP4 with QuickLook compatibility (`-movflags +faststart` and `-tag:v hvc1` for HEVC)
  - Checks codec compatibility before remuxing (skips incompatible codecs like WMV3 with a warning)
  - This ensures files that should be remuxed are handled before skip checks, preventing them from being skipped when they need remuxing
- **Codec compatibility checking**: Added `is_codec_mp4_compatible()` function to check if a video codec can be copied into MP4 without transcoding. Incompatible codecs (wmv3, wmv1, wmv2, vc1, rv40, rv30, theora) are skipped with a clear warning message, preventing remux failures.

### Modularization
- Refactored script into focused functions for better maintainability
- Separated concerns: utility functions, configuration, transcoding, and orchestration
- Main execution flow clearly visible in `main()` function

### Bug Fixes
- Fixed `bc` parse errors by sanitizing all values (removing newlines/whitespace) before passing to `bc`
- Fixed function return value corruption by redirecting logging functions to stderr
- Added value sanitization throughout to prevent issues with `ffprobe` and `bc` outputs containing trailing newlines
- Added QuickLook compatibility: `-movflags +faststart` for sample transcoding; both `-movflags +faststart` and `-tag:v hvc1` for final output to ensure macOS Finder preview support
- Fixed short-circuit logic: Added check for source bitrate below target (previously only checked within tolerance range)
- Fixed incorrect info message about quality values (corrected "lower = higher quality" to "higher = higher quality/bitrate")
- Fixed integer conversion error in proportional adjustment: Quality adjustment values are now properly rounded to integers using `printf "%.0f"` before use in arithmetic operations, preventing "integer expression expected" errors

## Current Limitations

1. **macOS-only**: Currently only supports macOS (VideoToolbox hardware acceleration requires macOS)
2. **Subdirectory depth**: Default depth is 2 levels (current directory + one subdirectory level), but configurable via `-L`/`--max-depth` flag (use `-L 0` for unlimited recursive search)
3. **Hardcoded defaults**: Bitrates, codec, and container are fixed (though target bitrate can be overridden via `--target-bitrate` flag)
4. **Limited configuration**: No config file support yet (only command-line overrides for target bitrate and depth)
5. **No installation**: Script must be run directly, not installed as system command
6. **Audio handling**: Always copies audio without re-encoding options

## Future Direction

This is a proof-of-concept project focused on iterating over ergonomics and usability on macOS. The current implementation leverages macOS-specific hardware acceleration via VideoToolbox. Future improvements will be determined based on usage patterns and needs as the project evolves. Cross-platform support (Linux/Windows) may be considered in the future, but the current focus is on optimizing the macOS experience. See [PLAN.md](PLAN.md) and [README.md](README.md) for current status and potential future enhancements.

## Design Decisions

### Why constant quality mode (`-q:v`) instead of bitrate mode?

VideoToolbox HEVC encoder supports constant quality mode via `-q:v` parameter (0-100 scale). This approach is similar to HandBrake's RF mode and CRF mode in software encoders. The iterative approach adjusts the quality value until the actual output bitrate matches the target, allowing the encoder to adapt bitrate to content complexity. This reduces blocky artifacts compared to fixed bitrate encoding.

### Why multi-point sampling?

Sampling from multiple points (beginning, middle, end) provides a more accurate representation of overall video complexity. A single sample from the beginning might not represent the full video, especially if complexity varies throughout.

### Why 60-second samples?

Longer samples provide more accurate bitrate measurements by averaging out variation within each sample. 60 seconds balances accuracy with iteration time. For longer videos, 3 samples per iteration provide 180 seconds of total sampling, which significantly improves bitrate targeting accuracy.

### Why ±5% tolerance?

Allows for natural variation in bitrate while still achieving the target. Too strict would require excessive iterations; too loose would miss the target.

### Why VideoToolbox instead of libx265?

Hardware acceleration on macOS Sequoia provides significantly faster encoding while maintaining quality. VideoToolbox is optimized for Apple Silicon and Intel Macs with hardware HEVC support.

### Why no iteration limit?

The optimization loop continues until convergence (bitrate within ±5% tolerance), oscillation detection, or quality bounds are reached (0 or 100). This allows the algorithm to find the optimal quality setting regardless of how many iterations it takes. Quality bounds prevent infinite loops by capping the adjustment range. Oscillation detection prevents infinite cycling when tight tolerances cause the algorithm to alternate between quality values that don't quite meet the tolerance threshold.

### Why modularize into functions?

The script was refactored into functions to improve:
- **Maintainability**: Each function has a single, clear responsibility
- **Readability**: The main execution flow is clear in the `main()` function
- **Testability**: Individual functions can be tested in isolation
- **Reusability**: Functions can be called independently if needed

### Value Sanitization

All values passed to `bc` are sanitized using `tr -d '\n\r' | xargs` to:
- Remove newlines and carriage returns that can cause `bc` parse errors
- Trim leading/trailing whitespace
- Ensure clean numeric values for calculations

This is critical because `ffprobe` and `bc` outputs may contain trailing newlines that cause parse errors when passed to subsequent `bc` calculations.

### QuickLook Compatibility

The script includes flags to ensure macOS Finder QuickLook compatibility:
- **`-movflags +faststart`**: Moves metadata (moov atom) to the beginning of the file, allowing QuickLook to read file information immediately without scanning the entire file. Applied to both sample transcoding and final output.
- **`-tag:v hvc1`**: Ensures proper HEVC codec tagging in the MP4 container for better compatibility with macOS QuickTime/QuickLook. Applied only to the final transcoded output (not to temporary sample files).

Sample files use `-movflags +faststart` for faster bitrate measurement, while the final output includes both flags for full QuickLook compatibility.

