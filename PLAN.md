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

- [x] Automatic video file discovery in current directory and subdirectories (one level deep)
- [x] Batch processing: Processes all video files found in current directory and subdirectories
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
- [x] Early exit check: Skip transcoding if source video is already within ±5% of target bitrate
- [x] Helper scripts for testing (copy test videos, cleanup)
- [x] Comprehensive test suite with function mocking (111 tests, CI/CD ready)
- [x] Second pass transcoding: Automatically performs a second transcoding pass with adjusted quality if the first pass bitrate is outside tolerance range

### Current Defaults

- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (hardware-accelerated)
- **Quality control**: Constant quality mode (`-q:v`) - Iteratively adjusts quality value (0-100, higher = higher quality/bitrate) to hit target bitrate
- **Starting quality**: 52
- **Quality adjustment**: Proportional adjustment algorithm (minimum step: 1, maximum step: 10) based on distance from target
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
- **Testing infrastructure**: Implemented comprehensive test suite with function mocking using file-based call tracking. 111 tests covering utility functions, mocked FFmpeg/ffprobe functions, and full `main()` integration (including second pass transcoding scenarios). Tests work without FFmpeg/ffprobe installation, enabling CI/CD workflows. Uses temporary files for call tracking to work around bash subshell limitations.
- **Sample duration**: Sample duration is set to 60 seconds for better bitrate accuracy. Adaptive sampling logic uses fewer samples for shorter videos (1 sample for videos <120s, 2 samples for 120-179s, 3 samples for ≥180s).
- **FFmpeg process cleanup**: Signal handling implemented to kill process group on interrupt, but may need verification.

## Future Enhancements

### Smart Pre-processing

- [x] **Skip already optimized files**: Exit early if the source file is already within ±5% of the target bitrate for its resolution. This prevents unnecessary transcoding when the file is already optimized. (Implemented)

### Batch Processing

- [x] **Multiple files in current directory**: Process all video files found in the current directory, not just the first one. This allows transcoding multiple videos in a single run. (Implemented)
- [x] **Subdirectory processing (one level deep)**: Process video files in subdirectories one level deep from the current directory. This enables batch processing of organized video collections. (Implemented)

### File Detection and Naming

- [ ] **Detect already transcoded files**: Add logic to detect files that have already been transcoded based on the file naming convention. This would prevent re-transcoding files that have already been processed.
- [ ] **Programmatic file naming convention**: Establish and implement a consistent, programmatically detectable naming convention for transcoded files. This convention should:
  - Be easily identifiable as a transcoded file
  - Allow detection of the original source file
  - Support the detection feature above
  - Be consistent and predictable for automation
- [x] **Rename files to include bitrate information**: Files are now renamed to include their actual bitrate in the filename:
  - **Transcoded files**: `{base}.fmpg.{actual_bitrate}.Mbps.{ext}` (e.g., `video.fmpg.10.25.Mbps.mp4`)
  - **Files below target**: `{base}.orig.{actual_bitrate}.Mbps.{ext}` (e.g., `video.orig.2.90.Mbps.mp4`)
  - Actual bitrate is measured after transcoding and included with 2 decimal places for precision

### Quality Control and Optimization

- [ ] **Configurable constant quality start ranges**: Allow users to specify custom starting quality values or ranges for the optimization loop, rather than always starting at a fixed value (currently 52). This would help optimize for different use cases or content types.
- [ ] **Configurable sample duration**: Make the sample duration configurable. Currently set to 60 seconds per sample. Longer samples provide more accurate bitrate predictions but take longer to process. Could be made user-configurable or further optimized based on video duration/complexity.

### Development Workflow

- [ ] **Account-wide Cursor configuration for "remember what you need to" convention**: Explore options for making the PROJECT-CONTEXT.md/PLAN.md/README.md update convention reusable across projects. Options to investigate:
  - Custom command template in `~/.cursor/command-templates/` that can be copied to each project's `.cursor/commands/` directory
  - Global `.cursorrules` file in home directory (`~/.cursorrules`) if Cursor supports account-wide rules
  - Other Cursor configuration mechanisms for account-wide AI behavior patterns
