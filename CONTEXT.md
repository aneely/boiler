# Context: Video Transcoding Tool

## Overview

This project provides a simplified command-line interface for transcoding video files on macOS. The tool automatically determines optimal encoding settings to achieve target bitrates while maintaining quality, making video compression accessible without deep knowledge of FFmpeg parameters. Currently macOS-only, with potential for cross-platform support in the future.

## Development Workflow

**Important**: Before adding or modifying items in [PLAN.md](PLAN.md), please discuss the proposed changes with the project maintainer. Planning decisions should be made collaboratively through conversation rather than unilaterally updating the plan document.

## Current Implementation

### Architecture

The tool is implemented as a modular bash script (`boiler.sh`) organized into focused functions:

1. **Discovers video files** in the current working directory
2. **Analyzes video properties** (resolution, duration) using `ffprobe`
3. **Determines target bitrate** based on resolution
4. **Iteratively finds optimal bitrate setting** by transcoding samples from multiple points
5. **Transcodes the full video** using the optimal settings

#### Code Organization

The script is modularized into the following function categories:

**Utility Functions:**
- `check_requirements()` - Validates that ffmpeg, ffprobe, and bc are installed
- `find_video_file()` - Discovers video files in the current directory
- `get_video_resolution()` - Extracts video resolution using ffprobe
- `get_video_duration()` - Extracts video duration using ffprobe

**Configuration Functions:**
- `calculate_target_bitrate()` - Determines target bitrate based on resolution
- `calculate_sample_points()` - Calculates sample points (10%, 50%, 90%) with bounds checking

**Transcoding Functions:**
- `transcode_sample()` - Transcodes a single sample from a specific point
- `measure_sample_bitrate()` - Measures actual bitrate from a sample file
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

1. **Initial bitrate**: Starts with the target bitrate as the initial guess
2. **Multi-point sampling**: Creates 15-second samples from 3 points in the video:
   - Beginning (~10% through video)
   - Middle (~50% through video)
   - End (~90% through video)
3. **Bitrate measurement**: Averages bitrates from all 3 samples using `ffprobe` or file size calculation
4. **Adjustment logic**:
   - If actual bitrate too low: Increase bitrate setting by 10%
   - If actual bitrate too high: Decrease bitrate setting by 10%
5. **Convergence**: Stops when actual bitrate is within ±10% of target
6. **Safety limits**: Maximum 10 iterations, exits with error if not converged

#### Encoding Settings

**Current defaults:**
- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (Apple VideoToolbox hardware acceleration)
- **Quality control**: Bitrate mode (`-b:v`) - VideoToolbox doesn't support CRF
- **Container**: MP4
- **Audio**: Copy (no re-encoding)
- **Output naming**: `{original_name}_transcoded.mp4`
- **Platform**: Optimized for macOS Sequoia (hardware acceleration unlocked)

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
├── CONTEXT.md                   # Technical documentation
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

### Modularization (Latest)
- Refactored script into focused functions for better maintainability
- Separated concerns: utility functions, configuration, transcoding, and orchestration
- Main execution flow clearly visible in `main()` function

### Bug Fixes (Latest)
- Fixed `bc` parse errors by sanitizing all values (removing newlines/whitespace) before passing to `bc`
- Fixed function return value corruption by redirecting logging functions to stderr
- Added value sanitization throughout to prevent issues with `ffprobe` and `bc` outputs containing trailing newlines

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

