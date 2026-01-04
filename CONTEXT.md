# Context: Video Transcoding Tool

## Overview

This project provides a simplified command-line interface for transcoding video files. The tool automatically determines optimal encoding settings to achieve target bitrates while maintaining quality, making video compression accessible without deep knowledge of FFmpeg parameters.

## Current Implementation

### Architecture

The tool is implemented as a single bash script (`boiler.sh`) that:

1. **Discovers video files** in the current working directory
2. **Analyzes video properties** (resolution) using `ffprobe`
3. **Determines target bitrate** based on resolution
4. **Iteratively finds optimal CRF value** by transcoding short samples
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

The script uses an iterative approach to find the optimal Constant Rate Factor (CRF):

1. **Initial CRF**: Starts at 23 (reasonable default for x265)
2. **Sample transcoding**: Creates 15-second samples at different CRF values
3. **Bitrate measurement**: Uses `ffprobe` or file size calculation to measure actual bitrate
4. **Adjustment logic**:
   - If bitrate too low: Decrease CRF (higher quality, higher bitrate)
   - If bitrate too high: Increase CRF (lower quality, lower bitrate)
5. **Convergence**: Stops when bitrate is within ±10% of target
6. **Safety limits**: CRF constrained between 0-51, max 20 iterations

#### Encoding Settings

**Current defaults:**
- **Codec**: HEVC (H.265) via `libx265`
- **Preset**: `medium` (balance of speed and compression)
- **Container**: MP4
- **Audio**: Copy (no re-encoding)
- **Output naming**: `{original_name}_transcoded.mp4`

### Dependencies

- **ffmpeg**: Video encoding/transcoding
- **ffprobe**: Video analysis and metadata extraction
- **bc**: Arbitrary precision calculator for bitrate calculations

### File Structure

```
boiler/
├── boiler.sh                    # Main transcoding script
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

### Why CRF instead of target bitrate mode?

CRF (Constant Rate Factor) provides better quality consistency across different content types. The iterative approach allows us to approximate target bitrates while maintaining quality.

### Why 15-second samples?

Balances speed (shorter samples = faster iterations) with accuracy (longer samples = more representative bitrate). 15 seconds provides good compromise.

### Why ±10% tolerance?

Allows for natural variation in bitrate while still achieving the target. Too strict would require excessive iterations; too loose would miss the target.

### Why medium preset?

Balances encoding speed with compression efficiency. Faster presets reduce quality; slower presets take too long for iterative testing.

