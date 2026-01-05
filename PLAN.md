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
- [x] Iterative quality optimization algorithm using constant quality mode (`-q:v`)
- [x] Multi-point sampling (beginning, middle, end) for accurate bitrate prediction
- [x] HEVC via Apple VideoToolbox (hardware-accelerated on macOS)
- [x] MP4 container format
- [x] Audio stream copying (no re-encoding)
- [x] Color-coded output messages
- [x] Error handling and validation
- [x] Early exit check: Skip transcoding if source video is already within ±10% of target bitrate
- [x] Helper scripts for testing (copy test videos, cleanup)

### Current Defaults

- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (hardware-accelerated)
- **Quality control**: Constant quality mode (`-q:v`) - Iteratively adjusts quality value (0-100, higher = higher quality/bitrate) to hit target bitrate
- **Starting quality**: 30 (adjustable)
- **Quality step size**: 2 (adjustable)
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
- **Constant quality mode**: Switched from bitrate mode (`-b:v`) to constant quality mode (`-q:v`) to match HandBrake's approach and reduce blocky artifacts. Quality value (0-100) is iteratively adjusted to hit target bitrate.
- **Multi-point sampling**: Implemented to address issue where single sample from beginning didn't accurately predict full video bitrate.
- **No iteration limit**: Removed iteration limit safeguard - loop continues until convergence or quality bounds (0-100) are reached.
- **Code refactoring**: Consolidated duplicate bitrate measurement logic into generic `measure_bitrate()` function. Extracted tolerance checking into `is_within_tolerance()` helper. Added `sanitize_value()` helper for consistent value sanitization. Renamed `find_optimal_bitrate()` to `find_optimal_quality()` to reflect constant quality mode.
- **Performance issue with large files**: Sample duration is hardcoded to 15 seconds, causing very long iteration times for large 2160p files. Adaptive sample duration based on file size has been tested and works well, but needs to be implemented.
- **FFmpeg process cleanup**: Signal handling implemented to kill process group on interrupt, but may need verification.

## Future Enhancements

### Smart Pre-processing

- [x] **Skip already optimized files**: Exit early if the source file is already within ±10% of the target bitrate for its resolution. This prevents unnecessary transcoding when the file is already optimized. (Implemented)

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
- [ ] **Rename files to include quality setting**: Include the quality value (e.g., `-q:v 45`) in the output filename so users can identify which quality setting was used for each transcoded file. Example: `video_q45_transcoded.mp4`

### Quality Control and Optimization

- [ ] **Configurable constant quality start ranges**: Allow users to specify custom starting quality values or ranges for the optimization loop, rather than always starting at a fixed value (currently 30). This would help optimize for different use cases or content types.
- [ ] **Lengthen optimization sample sizes**: Make the sample duration configurable or adaptive. Currently hardcoded to 15 seconds per sample. Longer samples would provide more accurate bitrate predictions but take longer to process. Could be made user-configurable or adaptive based on video duration/complexity.
