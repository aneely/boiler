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
- **ONLY provide an explanation or answer** - do NOT implement anything
- Explain the approach, solution, or answer to their question
- Wait for explicit request like "implement this", "add this", "make this change" before making any code changes
- Questions are for learning and discussion, not automatic implementation

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
5. **Iteratively finds optimal quality setting** using constant quality mode (`-q:v`) by transcoding samples from multiple points and adjusting quality to hit target bitrate
6. **Transcodes the full video** using the optimal quality setting

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
- `calculate_sample_points()` - Calculates sample points with adaptive logic: 3 samples for videos ≥180s, 2 samples for 120-179s, 1 sample for shorter videos. Uses 60-second samples (or full video for videos <60s)

**Transcoding Functions:**
- `transcode_sample()` - Transcodes a single sample from a specific point using constant quality mode (`-q:v`)
- `measure_sample_bitrate()` - Measures actual bitrate from a sample file (wrapper around `measure_bitrate()`)
- `find_optimal_quality()` - Main optimization loop that iteratively finds optimal quality setting by adjusting `-q:v` to hit target bitrate
- `transcode_full_video()` - Transcodes the complete video with optimal quality setting
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

The script uses an iterative approach to find the optimal quality setting using constant quality mode:

1. **Pre-check**: Before starting optimization, checks if source video is already within ±10% of target bitrate OR if source bitrate is below target. If either condition is true, exits early with a message indicating no transcoding is needed.
2. **Initial quality**: Starts with quality value 52 (VideoToolbox `-q:v` scale: 0-100, higher = higher quality/bitrate)
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
6. **Convergence**: Stops when actual bitrate is within ±10% of target
7. **No iteration limit**: Loop continues indefinitely until convergence or quality bounds are reached

#### Encoding Settings

**Current defaults:**
- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (Apple VideoToolbox hardware acceleration)
- **Quality control**: Constant quality mode (`-q:v`) - Iteratively adjusts quality value (0-100, higher = higher quality/bitrate) to hit target bitrate
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
- Starting quality value: 52 (increased from 30 for faster convergence)

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

- Configurable constant quality start ranges
- Rename files to include quality setting in filename

### Smart Pre-processing
- Added early exit check: If source video is already within ±10% of target bitrate OR if source bitrate is below target, the script exits immediately with a helpful message, avoiding unnecessary transcoding work
- Uses the same tolerance logic (±10%) and comparison method as the optimization loop for consistency
- `get_source_bitrate()` function measures source video bitrate using the same approach as sample measurement (ffprobe first, file size fallback)
- Handles both cases: videos already at target (within tolerance) and videos already more compressed than target (below target bitrate)

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
2. **Single file processing**: Only processes one video per execution
3. **Directory constraint**: Must be run from directory containing video file
4. **Hardcoded defaults**: Bitrates, codec, and container are fixed
5. **No configuration**: No user-configurable settings
6. **No installation**: Script must be run directly, not installed as system command
7. **Audio handling**: Always copies audio without re-encoding options

## Future Direction

This is a proof-of-concept project focused on iterating over ergonomics and usability on macOS. The current implementation leverages macOS-specific hardware acceleration via VideoToolbox. Future improvements will be determined based on usage patterns and needs as the project evolves. Cross-platform support (Linux/Windows) may be considered in the future, but the current focus is on optimizing the macOS experience. See [PLAN.md](PLAN.md) and [README.md](README.md) for current status and potential future enhancements.

## Design Decisions

### Why constant quality mode (`-q:v`) instead of bitrate mode?

VideoToolbox HEVC encoder supports constant quality mode via `-q:v` parameter (0-100 scale). This approach is similar to HandBrake's RF mode and CRF mode in software encoders. The iterative approach adjusts the quality value until the actual output bitrate matches the target, allowing the encoder to adapt bitrate to content complexity. This reduces blocky artifacts compared to fixed bitrate encoding.

### Why multi-point sampling?

Sampling from multiple points (beginning, middle, end) provides a more accurate representation of overall video complexity. A single sample from the beginning might not represent the full video, especially if complexity varies throughout.

### Why 60-second samples?

Longer samples provide more accurate bitrate measurements by averaging out variation within each sample. 60 seconds balances accuracy with iteration time. For longer videos, 3 samples per iteration provide 180 seconds of total sampling, which significantly improves bitrate targeting accuracy.

### Why ±10% tolerance?

Allows for natural variation in bitrate while still achieving the target. Too strict would require excessive iterations; too loose would miss the target.

### Why VideoToolbox instead of libx265?

Hardware acceleration on macOS Sequoia provides significantly faster encoding while maintaining quality. VideoToolbox is optimized for Apple Silicon and Intel Macs with hardware HEVC support.

### Why no iteration limit?

The optimization loop continues until convergence (bitrate within ±10% tolerance) or quality bounds are reached (0 or 100). This allows the algorithm to find the optimal quality setting regardless of how many iterations it takes. Quality bounds prevent infinite loops by capping the adjustment range.

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

