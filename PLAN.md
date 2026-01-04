# Project Plan: Video Transcoding Tool

## Project Goals

Create a simplified command-line tool for video transcoding that:
- Provides sensible defaults for common use cases
- Automatically optimizes quality settings
- Can be easily installed and used from any directory
- Supports user-configurable preferences

## Current Status (v0.1)

### ✅ Implemented Features

- [x] Automatic video file discovery in current directory
- [x] Resolution-based target bitrate selection
  - 2160p: 11 Mbps
  - 1080p: 8 Mbps
- [x] Iterative CRF optimization algorithm
- [x] HEVC/x265 codec with medium preset
- [x] MP4 container format
- [x] Audio stream copying (no re-encoding)
- [x] Color-coded output messages
- [x] Error handling and validation
- [x] Sample-based quality testing (15-second samples)

### Current Defaults

- **Codec**: HEVC (H.265) via `libx265`
- **Container**: MP4
- **Preset**: `medium`
- **Audio**: Copy (passthrough)
- **Target Bitrates**:
  - 2160p: 11 Mbps
  - 1080p: 8 Mbps
