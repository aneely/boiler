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

This ensures the user maintains control over the development direction and can make informed decisions about which solutions best fit their needs.

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

1. **Discovers video files** in the current working directory
2. **Analyzes video properties** (resolution, duration) using `ffprobe`
3. **Determines target bitrate** based on resolution
4. **Checks if source is already optimized** - Short-circuits if source video is already within ±10% of target bitrate
5. **Iteratively finds optimal bitrate setting** by transcoding samples from multiple points (if needed)
6. **Transcodes the full video** using the optimal settings

#### Code Organization

The script is modularized into the following function categories:

**Utility Functions:**
- `check_requirements()` - Validates that ffmpeg, ffprobe, and bc are installed
- `find_video_file()` - Discovers video files in the current directory
- `get_video_resolution()` - Extracts video resolution using ffprobe
- `get_video_duration()` - Extracts video duration using ffprobe
- `sanitize_value()` - Sanitizes values for bc calculations (removes newlines, carriage returns, trims whitespace)
- `measure_bitrate()` - Generic function to measure bitrate from any video file (ffprobe first, file size fallback)
- `get_source_bitrate()` - Measures source video bitrate (wrapper around `measure_bitrate()`)
- `is_within_tolerance()` - Checks if a bitrate is within the acceptable tolerance range (±10%)

**Configuration Functions:**
- `calculate_target_bitrate()` - Determines target bitrate based on resolution
- `calculate_sample_points()` - Calculates sample points (10%, 50%, 90%) with bounds checking

**Transcoding Functions:**
- `transcode_sample()` - Transcodes a single sample from a specific point
- `measure_sample_bitrate()` - Measures actual bitrate from a sample file (wrapper around `measure_bitrate()`)
- `find_optimal_bitrate()` - Main optimization loop that iteratively finds optimal bitrate
- `transcode_full_video()` - Transcodes the complete video with optimal settings
- `cleanup_samples()` - Removes temporary sample files

**Main Orchestration:**
- `main()` - Orchestrates all steps in the correct order

**Logging Functions:**
- `info()`, `warn()`, `error()` - Color-coded output functions (output to stderr to avoid interfering with function return values)

### Core Components

#### Video Discovery
- Searches current directory for common video formats: `mp4`, `mkv`, `avi`, `mov`, `m4v`, `webm`, `flv`, `wmv`
- Selects the first matching file found
- Requires exactly one video file in the directory

#### Resolution Detection
- Uses `ffprobe` to extract video stream height
- Categorizes videos into resolution tiers:
  - **2160p (4K)**: ≥2160 pixels height
  - **1080p (Full HD)**: ≥1080 pixels height
  - **Below 1080p**: Falls back to 1080p settings

#### Bitrate Targeting
- **2160p videos**: Target 11 Mbps
- **1080p videos**: Target 8 Mbps
- Acceptable range: ±10% of target bitrate

#### Quality Optimization Algorithm

The script uses an iterative approach to find the optimal bitrate setting:

1. **Pre-check**: Before starting optimization, checks if source video is already within ±10% of target bitrate. If so, exits early with a message indicating no transcoding is needed.
2. **Initial bitrate**: Starts with the target bitrate as the initial guess
3. **Multi-point sampling**: Creates 15-second samples from 3 points in the video:
   - Beginning (~10% through video)
   - Middle (~50% through video)
   - End (~90% through video)
4. **Bitrate measurement**: Averages bitrates from all 3 samples using `ffprobe` or file size calculation
5. **Adjustment logic**:
   - If actual bitrate too low: Increase bitrate setting by 10%
   - If actual bitrate too high: Decrease bitrate setting by 10%
6. **Convergence**: Stops when actual bitrate is within ±10% of target
7. **Safety limits**: Maximum 10 iterations, exits with error if not converged

#### Encoding Settings

**Current defaults:**
- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (Apple VideoToolbox hardware acceleration)
- **Quality control**: Bitrate mode (`-b:v`) - VideoToolbox doesn't support CRF
- **Container**: MP4
- **Audio**: Copy (no re-encoding)
- **Output naming**: `{original_name}_transcoded.mp4`
- **Platform**: Optimized for macOS Sequoia (hardware acceleration unlocked)
- **QuickLook compatibility**: Uses `-movflags +faststart` for sample transcoding; both `-movflags +faststart` and `-tag:v hvc1` for final output to ensure macOS Finder QuickLook support

### Dependencies

- **ffmpeg**: Video encoding/transcoding
- **ffprobe**: Video analysis and metadata extraction
- **bc**: Arbitrary precision calculator for bitrate calculations

### File Structure

```
boiler/
├── boiler.sh                    # Main transcoding script
├── copy-1080p-test.sh          # Helper: Copy 1080p test video to current directory
├── copy-4k-test.sh              # Helper: Copy 4K test video to current directory
├── cleanup-mp4.sh               # Helper: Remove all .mp4 files from project root
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

## Current Session Status

### Tested but Not Yet Committed

**Performance Optimizations (tested, working, needs implementation):**
- **Adaptive sample duration based on file size**: Tested implementation that adjusts sample duration based on file size thresholds:
  - >10GB: 5 seconds per sample
  - >5GB: 7 seconds per sample
  - >2GB: 10 seconds per sample
  - ≤2GB: 15 seconds per sample (default)
  - This significantly reduces iteration time for large 2160p files
  - Implementation: Modify `calculate_sample_points()` to accept file size parameter and calculate adaptive duration

- **Input seeking optimization**: Tested change to move `-ss` flag before `-i` in `transcode_sample()` function:
  - Changed from: `ffmpeg -y -i "$video_file" -ss "$sample_start" ...`
  - Changed to: `ffmpeg -y -ss "$sample_start" -i "$video_file" ...`
  - This uses input seeking instead of output seeking, making all three samples roughly the same speed
  - **Known issue**: This change causes FFmpeg child processes to not be properly cleaned up when script is interrupted (Ctrl+C)

### Known Issues

- **FFmpeg processes not cleaned up on interrupt**: When using input seeking (`-ss` before `-i`), interrupting the script (Ctrl+C) leaves FFmpeg child processes running. Signal handling needs to be implemented to properly kill child processes on interrupt.
- **Sample duration**: Currently hardcoded to 15 seconds. For large 2160p files, this causes very long iteration times (each sample taking minutes to transcode).

### Next Steps

1. Implement adaptive sample duration based on file size (tested, working)
2. Implement input seeking optimization (tested, working)
3. Add signal handling to properly clean up FFmpeg processes on interrupt (needed to fix issue with input seeking)

### Smart Pre-processing
- Added early exit check: If source video is already within ±10% of target bitrate, the script exits immediately with a helpful message, avoiding unnecessary transcoding work
- Uses the same tolerance logic (±10%) and comparison method as the optimization loop for consistency
- `get_source_bitrate()` function measures source video bitrate using the same approach as sample measurement (ffprobe first, file size fallback)

### Modularization
- Refactored script into focused functions for better maintainability
- Separated concerns: utility functions, configuration, transcoding, and orchestration
- Main execution flow clearly visible in `main()` function

### Bug Fixes
- Fixed `bc` parse errors by sanitizing all values (removing newlines/whitespace) before passing to `bc`
- Fixed function return value corruption by redirecting logging functions to stderr
- Added value sanitization throughout to prevent issues with `ffprobe` and `bc` outputs containing trailing newlines
- Added QuickLook compatibility: `-movflags +faststart` for sample transcoding; both `-movflags +faststart` and `-tag:v hvc1` for final output to ensure macOS Finder preview support

## Current Limitations

1. **macOS-only**: Currently only supports macOS (VideoToolbox hardware acceleration requires macOS)
2. **Single file processing**: Only processes one video per execution
3. **Directory constraint**: Must be run from directory containing video file
4. **Hardcoded defaults**: Bitrates, codec, and container are fixed
5. **No configuration**: No user-configurable settings
6. **No installation**: Script must be run directly, not installed as system command
7. **Audio handling**: Always copies audio without re-encoding options

## Future Direction

This is a proof-of-concept project focused on iterating over ergonomics and usability on macOS. The current implementation leverages macOS-specific hardware acceleration via VideoToolbox. Future improvements will be determined based on usage patterns and needs as the project evolves. Cross-platform support (Linux/Windows) may be considered in the future, but the current focus is on optimizing the macOS experience. See [PLAN.md](PLAN.md) and [README.md](README.md) for current status and potential future enhancements.

## Design Decisions

### Why bitrate mode instead of CRF?

VideoToolbox HEVC encoder (used for hardware acceleration on macOS) doesn't support CRF mode - it only supports bitrate mode (`-b:v`). The iterative approach adjusts the bitrate setting until the actual output bitrate matches the target.

### Why multi-point sampling?

Sampling from multiple points (beginning, middle, end) provides a more accurate representation of overall video complexity. A single sample from the beginning might not represent the full video, especially if complexity varies throughout.

### Why 15-second samples?

Balances speed (shorter samples = faster iterations) with accuracy (longer samples = more representative bitrate). 15 seconds provides good compromise, and with 3 samples per iteration, we get 45 seconds of total sampling.

### Why ±10% tolerance?

Allows for natural variation in bitrate while still achieving the target. Too strict would require excessive iterations; too loose would miss the target.

### Why VideoToolbox instead of libx265?

Hardware acceleration on macOS Sequoia provides significantly faster encoding while maintaining quality. VideoToolbox is optimized for Apple Silicon and Intel Macs with hardware HEVC support.

### Why 10 iteration limit?

Prevents infinite loops if convergence isn't possible. The script exits with an error if it can't find optimal settings within 10 iterations, making failures explicit rather than silently continuing.

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

