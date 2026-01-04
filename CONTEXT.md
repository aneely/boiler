# Context: Video Transcoding Tool

## Overview

This project provides a simplified command-line interface for transcoding video files. The tool automatically determines optimal encoding settings to achieve target bitrates while maintaining quality, making video compression accessible without deep knowledge of FFmpeg parameters.

## Development Workflow

**Important**: Before adding or modifying items in [PLAN.md](PLAN.md), please discuss the proposed changes with the project maintainer. Planning decisions should be made collaboratively through conversation rather than unilaterally updating the plan document.

## Current Implementation

### Architecture

The tool is implemented as a single bash script (`boiler.sh`) that:

1. **Discovers video files** in the current working directory
2. **Analyzes video properties** (resolution, duration) using `ffprobe`
3. **Determines target bitrate** based on resolution
4. **Iteratively finds optimal bitrate setting** by transcoding samples from multiple points
5. **Transcodes the full video** using the optimal settings

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

### Output Formatting

- Color-coded messages:
  - **Green**: Informational messages
  - **Yellow**: Warnings
  - **Red**: Errors
- Progress indicators for iterations and transcoding status

## Current Limitations

1. **Single file processing**: Only processes one video per execution
2. **Directory constraint**: Must be run from directory containing video file
3. **Hardcoded defaults**: Bitrates, codec, and container are fixed
4. **No configuration**: No user-configurable settings
5. **No installation**: Script must be run directly, not installed as system command
6. **Audio handling**: Always copies audio without re-encoding options

## Future Direction

This is a proof-of-concept project focused on iterating over ergonomics and usability. Future improvements will be determined based on usage patterns and needs as the project evolves. See [PLAN.md](PLAN.md) and [README.md](README.md) for current status and potential future enhancements.

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

