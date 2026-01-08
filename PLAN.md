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
- [x] Smart file skipping: Automatically skips files that are already encoded (contain `.fmpg.`, `.orig.`, or `.hbrk.` markers) or have encoded versions in the same directory
- [x] Batch processing: Processes all video files found in current directory and subdirectories
- [x] Resolution-based target bitrate selection
  - 2160p: 11 Mbps
  - 1080p: 8 Mbps
  - 720p: 5 Mbps
  - 480p: 2.5 Mbps
- [x] Iterative quality optimization algorithm using constant quality mode (`-q:v`)
- [x] Multi-point sampling (beginning, middle, end) for accurate bitrate prediction
- [x] HEVC via Apple VideoToolbox (hardware-accelerated on macOS)
- [x] MP4 container format
- [x] Audio stream copying (no re-encoding)
- [x] Color-coded output messages
- [x] Error handling and validation
- [x] Early exit check: Skip transcoding if source video is already within ±5% of target bitrate
- [x] MKV remuxing: Automatically remuxes MKV files that are within tolerance or below target to MP4 with QuickLook compatibility (copies streams without transcoding)
- [x] Helper scripts for testing (copy test videos, cleanup)
- [x] Comprehensive test suite with function mocking (163 tests, CI/CD ready)
- [x] Second pass transcoding: Automatically performs a second transcoding pass with adjusted quality if the first pass bitrate is outside tolerance range
- [x] Preprocessing pass for non-QuickLook formats: Automatically remuxes non-QuickLook compatible files (mkv, wmv, avi, webm, flv) that are within tolerance or below target, including `.orig.` files, before main file discovery
- [x] Codec compatibility checking: Checks codec compatibility before remuxing to prevent failures with incompatible codecs (e.g., WMV3)

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
  - 720p: 5 Mbps
  - 480p: 2.5 Mbps
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
- **Testing infrastructure**: Implemented comprehensive test suite with function mocking using file-based call tracking. 138 tests covering utility functions, mocked FFmpeg/ffprobe functions, and full `main()` integration (including second pass transcoding scenarios, multiple resolution support, `calculate_adjusted_quality()` unit tests, and error handling tests). Tests work without FFmpeg/ffprobe installation, enabling CI/CD workflows. Uses temporary files for call tracking to work around bash subshell limitations.
- **Sample duration**: Sample duration is set to 60 seconds for better bitrate accuracy. Adaptive sampling logic uses fewer samples for shorter videos (1 sample for videos <120s, 2 samples for 120-179s, 3 samples for ≥180s).
- **FFmpeg process cleanup**: Signal handling implemented to kill process group on interrupt, but may need verification.

## Future Enhancements

### Smart Pre-processing

- [x] **Skip already optimized files**: Exit early if the source file is already within ±5% of the target bitrate for its resolution. This prevents unnecessary transcoding when the file is already optimized. (Implemented)
- [x] **MKV remuxing for optimized files**: For MKV files that are already within tolerance or below target bitrate, automatically remux them to MP4 with QuickLook compatibility. This converts the container format without transcoding video/audio streams, improving macOS Finder QuickLook compatibility while preserving quality. Uses `-movflags +faststart` and `-tag:v hvc1` (for HEVC) for optimal QuickLook support. (Implemented)
- [ ] **Initial pass to identify work**: Perform an initial pass over all discovered video files to capture all potential work and allow short-circuiting logic to filter down to untranscoded files before starting any transcoding. This prevents non-deterministic behavior where a file transcoded close to the target bitrate (but slightly out of tolerance) causes a second run of the script to attempt re-encoding an already good enough encoded file. The initial pass would identify files that are already within tolerance or have encoded versions, ensuring they are properly skipped before any transcoding begins.

### Batch Processing

- [x] **Multiple files in current directory**: Process all video files found in the current directory, not just the first one. This allows transcoding multiple videos in a single run. (Implemented)
- [x] **Subdirectory processing (one level deep)**: Process video files in subdirectories one level deep from the current directory. This enables batch processing of organized video collections. (Implemented)
- [ ] **Predictable file processing order**: Iterate over files in a predictable order (e.g., alphabetical) to ensure consistent behavior across runs and make batch processing more deterministic.

### File Detection and Naming

- [x] **Detect already transcoded files**: Logic implemented to detect files that have already been transcoded based on the file naming convention (`.fmpg.`, `.orig.`, `.hbrk.` markers). This prevents re-transcoding files that have already been processed. Uses `should_skip_file()`, `has_encoded_version()`, and `extract_original_filename()` functions. (Implemented)
- [x] **Programmatic file naming convention**: Established and implemented a consistent, programmatically detectable naming convention for transcoded files:
  - Easily identifiable as a transcoded file (via markers)
  - Allows detection of the original source file (via `extract_original_filename()`)
  - Supports the detection feature above
  - Consistent and predictable for automation (Implemented)
- [x] **Rename files to include bitrate information**: Files are now renamed to include their actual bitrate in the filename:
  - **Transcoded files**: `{base}.fmpg.{actual_bitrate}.Mbps.{ext}` (e.g., `video.fmpg.10.25.Mbps.mp4`)
  - **Files below target**: `{base}.orig.{actual_bitrate}.Mbps.{ext}` (e.g., `video.orig.2.90.Mbps.mp4`)
  - Actual bitrate is measured after transcoding and included with 2 decimal places for precision

### Quality Control and Optimization

- [ ] **Command-line bitrate override**: Add command-line argument support (e.g., `--target-bitrate 6.5`) to override the resolution-based target bitrate. The `transcode_video()` function already supports an optional target bitrate override parameter, so this would primarily involve adding argument parsing to the main script entry point. This would enable users to specify custom bitrates for specific transcoding operations without modifying the script.
- [ ] **Configurable target bitrates**: Allow users to customize target bitrates per resolution (2160p, 1080p, 720p, 480p) via configuration file or command-line options. This would enable users to adjust bitrates based on their specific quality/file size preferences, storage constraints, or use case requirements (e.g., archival vs. distribution).
- [ ] **SDR vs HDR bitrate differentiation**: Detect video dynamic range (Standard Dynamic Range vs. High Dynamic Range) and apply different target bitrates accordingly. HDR content typically requires higher bitrates (e.g., 6.5 Mbps for 720p HDR vs. 5 Mbps for 720p SDR, 35-45 Mbps for 4K HDR vs. current 11 Mbps for 4K SDR) to maintain quality due to increased color depth and brightness range. This would improve quality for HDR content while keeping file sizes reasonable for SDR content.
- [ ] **Configurable constant quality start ranges**: Allow users to specify custom starting quality values or ranges for the optimization loop, rather than always starting at a fixed value (currently 52). This would help optimize for different use cases or content types.
- [ ] **Configurable sample duration**: Make the sample duration configurable. Currently set to 60 seconds per sample. Longer samples provide more accurate bitrate predictions but take longer to process. Could be made user-configurable or further optimized based on video duration/complexity.

### Development Workflow

- [ ] **Account-wide Cursor configuration for "remember what you need to" convention**: Explore options for making the PROJECT-CONTEXT.md/PLAN.md/README.md update convention reusable across projects. Options to investigate:
  - Custom command template in `~/.cursor/command-templates/` that can be copied to each project's `.cursor/commands/` directory
  - Global `.cursorrules` file in home directory (`~/.cursorrules`) if Cursor supports account-wide rules
  - Other Cursor configuration mechanisms for account-wide AI behavior patterns
