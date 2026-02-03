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

**When the user talks about working on future enhancements but does not specify which item:**
- List what is left undone (from PLAN.md and any from this document).
- Decide together which one to work on.
- Do not implement anything until one item is chosen.

This ensures the user maintains control over the development direction and can make informed decisions about which solutions best fit their needs.

### Token Usage

**Always ask before taking action.** Do not execute commands, make edits, or perform multi-step operations without explicit user approval. Present options and wait for confirmation before proceeding. This applies especially to:
- Git operations (commits, pushes, resets)
- Destructive file modifications
- Installing or vendoring dependencies
- Any action that cannot be easily undone

### Reverting Changes

**Prefer version control over manual rollback.** To discard uncommitted changes and return the working directory to a known good state, use git:
- `git restore <file>...` or `git checkout -- <file>...` to discard changes in specific files.
- `git restore .` or `git checkout -- .` to discard all uncommitted changes in the working directory.

Do not manually edit or revert files line-by-line to undo changes. Using git to revert is simpler, faster, and avoids consuming tokens on repetitive edits.

### Testing Before Committing

**CRITICAL: MANDATORY TESTING REQUIREMENT**

**Before committing ANY changes, you MUST:**
1. **Run the test suite**: Execute `bash test_boiler.sh` and verify it completes successfully
2. **Verify exit code**: The test suite MUST exit with code 0 (all tests passing)
3. **Check test output**: Review the test summary to confirm all tests passed (e.g., "Passed: 259, Failed: 0")
4. **Fix any failures**: If ANY tests fail, you MUST fix the issues before committing
5. **NEVER commit without running tests**: Do not skip this step, even for minor changes

**This is a hard requirement - commits made without running tests are considered incomplete and should be amended.**

The test suite verifies:
- All utility functions work correctly
- No regressions were introduced
- Integration tests pass (main() function behavior)
- Mocked functions behave as expected

This ensures code quality and prevents regressions from being committed to the repository.

### Commit Messages

**Do not add `Co-authored-by:` or any other trailers to commit messages** unless the user explicitly asks for them. Use only the commit message body (subject and optional body) that the user or the task implies; do not append attribution lines.

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

The script is modularized into focused functions (utility, configuration, transcoding, orchestration); main execution flow is in `main()`. Function categories:

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
- **Predictable processing order**: File lists are sorted alphabetically (`sort`) so processing order is consistent across runs (main pass, preprocessing, and skipped-file display)
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

HEVC via `hevc_videotoolbox`, constant quality `-q:v` (0–100). Output naming: `{base}.fmpg.{actual_bitrate}.Mbps.{ext}` for transcoded; `{base}.orig.{actual_bitrate}.Mbps.{ext}` for below-target. QuickLook: `-movflags +faststart` and `-tag:v hvc1` on final output. Second/third pass behavior is described in Quality Optimization Algorithm above. Full user-facing defaults: see README.

### Dependencies

- **ffmpeg**: Video encoding/transcoding
- **ffprobe**: Video analysis and metadata extraction
- **bc**: Arbitrary precision calculator for bitrate calculations

### File Structure

```
boiler/
├── boiler.sh                    # Main transcoding script
├── test_boiler.sh               # Legacy test suite (271 tests, ~6s)
├── run-bats-tests.sh            # Bats test runner script
├── copy-1080p-test.sh           # Helper: Copy 1080p test video to current directory
├── copy-4k-test.sh              # Helper: Copy 4K test video to current directory
├── cleanup-mp4.sh               # Helper: Remove all .mp4 files from project root
├── cleanup-originals.sh         # Helper: Remove all .orig. marked video files. Supports -L/--max-depth.
├── remux-only.sh                # Helper: Remux video files to MP4. Supports -L/--max-depth.
├── .gitignore                   # Git ignore patterns (macOS, video files, outputs)
├── CLAUDE.md                    # Claude/AI assistant context
├── PROJECT-CONTEXT.md           # Technical documentation
├── PLAN.md                      # Development roadmap
├── README.md                    # User documentation
├── plans/                       # Detailed planning documents
│   └── (other plan files)
├── tests/                       # Bats test suite (217 tests, ~16s parallel)
│   ├── helpers/                 # Shared test utilities
│   │   ├── setup.bash           # Common test setup
│   │   └── mocks.bash           # FFmpeg/ffprobe mock functions
│   ├── test_helper/             # Bats helper libraries
│   │   ├── bats-support/
│   │   ├── bats-assert/
│   │   └── bats-file/
│   └── *.bats                   # Test files (15 files)
├── testdata/                    # Test video files
│   ├── videos/
│   │   ├── 1080p/               # 1080p test videos (gitignored)
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

### Testing

Dual test suite (legacy + bats); see README for how to run. Both suites use file-based call tracking to mock FFmpeg/ffprobe-dependent functions and work without FFmpeg/ffprobe installation (CI/CD ready). Run legacy suite during development for rapid iteration; run bats before commits for thorough verification.

### Known Issues

- **FFmpeg processes not cleaned up on interrupt**: When using input seeking (`-ss` before `-i`), interrupting the script (Ctrl+C) leaves FFmpeg child processes running. Signal handling is implemented but may need verification.

### Future Direction

See [PLAN.md](PLAN.md) and [README.md](README.md) for roadmap and user-facing future features. Architecture-affecting items (e.g. border detection/cropping) are tracked in PLAN.

## Current Limitations

- **macOS-only**: VideoToolbox requires macOS. Depth, bitrate override, and other user-facing limits are documented in README.

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

