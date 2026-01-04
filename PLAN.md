# Project Plan: Video Transcoding Tool

## Project Goals

Create a simplified command-line tool for video transcoding on macOS that:
- Provides sensible defaults for common use cases
- Automatically optimizes quality settings
- Leverages macOS hardware acceleration for fast encoding
- Can be easily installed and used from any directory
- Supports user-configurable preferences

**Note**: Currently macOS-only. Cross-platform support (Linux/Windows) may be considered in the future.

## Current Status (v0.2)

### ✅ Implemented Features

- [x] Automatic video file discovery in current directory
- [x] Resolution-based target bitrate selection
  - 2160p: 11 Mbps
  - 1080p: 8 Mbps
- [x] Iterative bitrate optimization algorithm
- [x] Multi-point sampling (beginning, middle, end) for accurate bitrate prediction
- [x] HEVC via Apple VideoToolbox (hardware-accelerated on macOS)
- [x] MP4 container format
- [x] Audio stream copying (no re-encoding)
- [x] Color-coded output messages
- [x] Error handling and validation
- [x] 10 iteration limit with error on failure to converge
- [x] Helper scripts for testing (copy test videos, cleanup)

### Current Defaults

- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (hardware-accelerated)
- **Quality control**: Bitrate mode (`-b:v`) - VideoToolbox doesn't support CRF
- **Container**: MP4
- **Audio**: Copy (passthrough)
- **Target Bitrates**:
  - 2160p: 11 Mbps
  - 1080p: 8 Mbps
- **Platform**: macOS Sequoia (hardware acceleration unlocked)

### Helper Scripts

- `copy-1080p-test.sh` - Copies 1080p test video to current directory
- `copy-4k-test.sh` - Copies 4K test video to current directory
- `cleanup-mp4.sh` - Removes all .mp4 files from project root directory

### Known Issues / Recent Changes

- **macOS-only**: Currently only supports macOS due to VideoToolbox hardware acceleration dependency. Cross-platform support may be added in the future.
- **VideoToolbox limitation**: VideoToolbox HEVC only supports bitrate mode, not CRF. The algorithm was changed from CRF-based to bitrate-based optimization.
- **Multi-point sampling**: Implemented to address issue where single sample from beginning didn't accurately predict full video bitrate.
- **Iteration limit**: Reduced from 20 to 10 iterations with error exit to prevent infinite loops.

## Future Enhancements

### Smart Pre-processing

- [ ] **Skip already optimized files**: Exit early if the source file is already below the target bitrate for its resolution. This prevents unnecessary transcoding when the file is already at or below the target bitrate.

### Batch Processing

- [ ] **Multiple files in current directory**: Process all video files found in the current directory, not just the first one. This would allow transcoding multiple videos in a single run.
- [ ] **Subdirectory processing (one level deep)**: Process video files in subdirectories one level deep from the current directory. This would enable batch processing of organized video collections.

### File Detection and Naming

- [ ] **Detect already transcoded files**: Add logic to detect files that have already been transcoded based on the file naming convention. This would prevent re-transcoding files that have already been processed.
- [ ] **Programmatic file naming convention**: Establish and implement a consistent, programmatically detectable naming convention for transcoded files. This convention should:
  - Be easily identifiable as a transcoded file
  - Allow detection of the original source file
  - Support the detection feature above
  - Be consistent and predictable for automation
