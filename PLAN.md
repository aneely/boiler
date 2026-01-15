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
- [x] Comprehensive test suite with function mocking (183 tests, CI/CD ready)
- [x] Second pass transcoding: Automatically performs a second transcoding pass with adjusted quality if the first pass bitrate is outside tolerance range
- [x] Preprocessing pass for non-QuickLook formats: Automatically remuxes non-QuickLook compatible files (mkv, wmv, avi, webm, flv) that are within tolerance or below target, including `.orig.` files, before main file discovery
- [x] Codec compatibility checking: Checks codec compatibility before remuxing to prevent failures with incompatible codecs (e.g., WMV3)

### Current Defaults

- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (hardware-accelerated)
- **Quality control**: Constant quality mode (`-q:v`) - Iteratively adjusts quality value (0-100, higher = higher quality/bitrate) to hit target bitrate
- **Starting quality**: 60
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
- `cleanup-originals.sh` - Removes all `.orig.` marked video files from current directory and subdirectories (moves to trash)

### Known Issues / Recent Changes

- **macOS-only**: Currently only supports macOS due to VideoToolbox hardware acceleration dependency. Cross-platform support may be added in the future.
- **Constant quality mode**: Switched from bitrate mode (`-b:v`) to constant quality mode (`-q:v`) to match HandBrake's approach and reduce blocky artifacts. Quality value (0-100) is iteratively adjusted to hit target bitrate.
- **Multi-point sampling**: Implemented to address issue where single sample from beginning didn't accurately predict full video bitrate.
- **No iteration limit**: Removed iteration limit safeguard - loop continues until convergence or quality bounds (0-100) are reached.
- **Code refactoring**: Consolidated duplicate bitrate measurement logic into generic `measure_bitrate()` function. Extracted tolerance checking into `is_within_tolerance()` helper. Added `sanitize_value()` helper for consistent value sanitization. Renamed `find_optimal_bitrate()` to `find_optimal_quality()` to reflect constant quality mode.
- **Testing infrastructure**: Implemented comprehensive test suite with function mocking using file-based call tracking. 183 tests covering utility functions, mocked FFmpeg/ffprobe functions, and full `main()` integration (including second pass transcoding scenarios, multiple resolution support, `calculate_adjusted_quality()` unit tests, codec compatibility checking, and error handling tests). Tests work without FFmpeg/ffprobe installation, enabling CI/CD workflows. Uses temporary files for call tracking to work around bash subshell limitations.
- **Sample duration**: Sample duration is set to 60 seconds for better bitrate accuracy. Adaptive sampling logic uses fewer samples for shorter videos (1 sample for videos <120s, 2 samples for 120-179s, 3 samples for ≥180s).
- **FFmpeg process cleanup**: Signal handling implemented to kill process group on interrupt, but may need verification.

## Future Enhancements

### Smart Pre-processing

- [x] **Skip already optimized files**: Exit early if the source file is already within ±5% of the target bitrate for its resolution. This prevents unnecessary transcoding when the file is already optimized. (Implemented)
- [x] **MKV remuxing for optimized files**: For MKV files that are already within tolerance or below target bitrate, automatically remux them to MP4 with QuickLook compatibility. This converts the container format without transcoding video/audio streams, improving macOS Finder QuickLook compatibility while preserving quality. Uses `-movflags +faststart` and `-tag:v hvc1` (for HEVC) for optimal QuickLook support. (Implemented)
- [ ] **Initial pass to identify work**: Perform an initial pass over all discovered video files to capture all potential work and allow short-circuiting logic to filter down to untranscoded files before starting any transcoding. This prevents non-deterministic behavior where a file transcoded close to the target bitrate (but slightly out of tolerance) causes a second run of the script to attempt re-encoding an already good enough encoded file. The initial pass would identify files that are already within tolerance or have encoded versions, ensuring they are properly skipped before any transcoding begins.
- [ ] **Single-pass remux and transcode**: Ensure that both the remuxing pass and transcoding pass happen in a single script execution, rather than requiring two separate runs. Currently, if a file gets remuxed in the preprocessing pass, it may not be picked up by the main transcoding pass in the same execution, requiring a second run. Implementation considerations:
  - **Re-scan after preprocessing**: After `preprocess_non_quicklook_files()` completes, re-scan for video files to include newly remuxed MP4 files that may still need transcoding (e.g., files that were remuxed but are above target bitrate)
  - **Track remuxed files**: Keep track of files that were remuxed during preprocessing and ensure they're included in the main processing pass if they still need transcoding
  - **File discovery logic**: Ensure `find_all_video_files()` picks up remuxed MP4 files that don't have skip markers (`.fmpg.`, `.orig.`, `.hbrk.`) and are above target bitrate
  - **Edge cases**: Handle cases where:
    - A file is remuxed from MKV to MP4 but is still above target bitrate and needs transcoding
    - A file is remuxed with an `.orig.` marker but the original file still exists and needs transcoding
    - Multiple files in the same directory where some get remuxed and others need transcoding
  This would eliminate the need to run the script twice (once for remux, once for transcode) and provide a smoother user experience.

### Batch Processing

- [x] **Multiple files in current directory**: Process all video files found in the current directory, not just the first one. This allows transcoding multiple videos in a single run. (Implemented)
- [x] **Subdirectory processing (one level deep)**: Process video files in subdirectories one level deep from the current directory. This enables batch processing of organized video collections. (Implemented)
- [x] **Configurable subdirectory depth**: Add support for traversing an arbitrary number of subdirectories with a configurable depth limit. Implementation considerations:
  - **Default depth**: Keep current default of 2 levels deep (current directory + one subdirectory level) for backward compatibility
  - **Command-line flag**: Add `-L` or `--max-depth` flag (matching `tree` command convention) to specify maximum directory depth
  - **Unlimited depth**: Support `-L 0` or `--max-depth 0` to traverse all subdirectories without limit (full recursive search)
  - **Usage examples**:
    - `./boiler.sh` - Default behavior (2 levels deep)
    - `./boiler.sh -L 1` - Current directory only (no subdirectories)
    - `./boiler.sh -L 3` - Three levels deep
    - `./boiler.sh -L 0` - Unlimited depth (full recursive)
  - **Implementation locations**: Update `find_all_video_files()`, `find_skipped_video_files()`, and `preprocess_non_quicklook_files()` to use configurable depth instead of hardcoded `-maxdepth 2`
  - **Validation**: Ensure depth value is a non-negative integer
  - **Documentation**: Update help text and README to explain the depth flag
  This would provide flexibility for users with deeply nested directory structures while maintaining the current default behavior. (Implemented)
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

- [x] **Command-line bitrate override**: Add command-line argument support (e.g., `--target-bitrate 6.5`) to override the resolution-based target bitrate. The `transcode_video()` function already supports an optional target bitrate override parameter, so this would primarily involve adding argument parsing to the main script entry point. This would enable users to specify custom bitrates for specific transcoding operations without modifying the script. (Implemented - supports `--target-bitrate` and `-t` flags, applies to all files)
- [ ] **Configurable target bitrates**: Allow users to customize target bitrates per resolution (2160p, 1080p, 720p, 480p) via configuration file or command-line options. This would enable users to adjust bitrates based on their specific quality/file size preferences, storage constraints, or use case requirements (e.g., archival vs. distribution).
- [ ] **SDR vs HDR bitrate differentiation**: Detect video dynamic range (Standard Dynamic Range vs. High Dynamic Range) and apply different target bitrates accordingly. HDR content typically requires higher bitrates (e.g., 6.5 Mbps for 720p HDR vs. 5 Mbps for 720p SDR, 35-45 Mbps for 4K HDR vs. current 11 Mbps for 4K SDR) to maintain quality due to increased color depth and brightness range. This would improve quality for HDR content while keeping file sizes reasonable for SDR content.
- [ ] **Configurable constant quality start ranges**: Allow users to specify custom starting quality values or ranges for the optimization loop, rather than always starting at a fixed value (currently 60). This would help optimize for different use cases or content types.
- [ ] **Configurable sample duration**: Make the sample duration configurable. Currently set to 60 seconds per sample. Longer samples provide more accurate bitrate predictions but take longer to process. Could be made user-configurable or further optimized based on video duration/complexity.
- [ ] **Historical logging and optimization analysis**: Implement a logging mechanism to track transcoding sessions for historical analysis and optimization opportunities. Logging should capture:
  - **File metadata**: File sizes, codecs, source bitrates, resolutions, durations
  - **Estimation attempts**: All iterative quality optimization attempts (quality values tested, resulting bitrates, convergence behavior, number of iterations)
  - **Transcode attempts**: All transcoding passes (first pass, second pass, third pass if needed) with quality values, target bitrates, actual bitrates, and outcomes
  - **Optimization insights**: Track patterns such as:
    - Whether quality tends to trend upward or downward from starting value (currently 60)
    - Optimal starting quality values for different content types/resolutions
    - Effectiveness of proportional adjustment algorithm
    - Sample-based prediction accuracy vs. full video results
    - Second/third pass success rates and adjustment effectiveness
  - **Storage format**: Structured data (e.g., JSON, CSV, or SQLite) that can be easily analyzed and queried
  - **Analysis tools**: Scripts or tools to analyze historical data to answer questions like:
    - Should we start at a different quality value (e.g., 55 or 65 instead of 60), perhaps depending on the resolution?
    - Do certain content types consistently require more iterations?
    - Is the proportional adjustment algorithm working well, or should we adjust min/max step sizes?
    - Are there patterns in overcorrection that could be addressed?
  This would enable data-driven optimization of the transcoding algorithm based on real-world usage patterns.

### Process Control

- [ ] **Suspend/Resume functionality**: Add support for suspending and resuming the transcoding process without terminating it. This would allow users to temporarily pause long-running transcoding jobs to free up system resources, then resume them later without losing progress. Implementation considerations:
  - **Signal handling**: Add signal handlers for `SIGTSTP` (Ctrl+Z, suspend) and `SIGCONT` (resume)
  - **Process group management**: When suspending, also suspend all child processes (FFmpeg) in the process group using `kill -STOP -- -$$`. When resuming, resume them with `kill -CONT -- -$$`
  - **State preservation**: The script already uses process groups (`kill -- -$$`), so child processes will automatically suspend/resume with the parent
  - **User feedback**: Provide clear messages when suspended/resumed (e.g., "Process suspended (Ctrl+Z). Use 'kill -CONT <PID>' to resume.")
  - **Usage patterns**:
    - Interactive shell: `Ctrl+Z` automatically sends `SIGTSTP`, can resume with `fg` or `kill -CONT %1`
    - Background process: Use `kill -STOP <PID>` to suspend, `kill -CONT <PID>` to resume
    - Process state: Suspended processes show as "T" (stopped) in `ps` output
  - **I/O considerations**: Suspending mid-transcode will pause FFmpeg operations. When resumed, transcoding continues from where it left off (no data loss, but may cause slight quality artifacts at the suspend/resume boundary depending on encoding state)
  - **Implementation example**:
    ```bash
    handle_suspend() {
        info "Process suspended (Ctrl+Z). Use 'kill -CONT $$' to resume."
        kill -STOP -- -$$ 2>/dev/null || true  # Suspend child processes
    }
    
    handle_resume() {
        info "Process resumed."
        kill -CONT -- -$$ 2>/dev/null || true  # Resume child processes
    }
    
    trap handle_suspend TSTP  # Ctrl+Z
    trap handle_resume CONT    # Resume signal
    ```
  This would be particularly useful for long-running batch transcoding jobs where users might want to temporarily pause processing to use system resources for other tasks.

### Development Workflow

- [ ] **Account-wide Cursor configuration for "remember what you need to" convention**: Explore options for making the PROJECT-CONTEXT.md/PLAN.md/README.md update convention reusable across projects. Options to investigate:
  - Custom command template in `~/.cursor/command-templates/` that can be copied to each project's `.cursor/commands/` directory
  - Global `.cursorrules` file in home directory (`~/.cursorrules`) if Cursor supports account-wide rules
  - Other Cursor configuration mechanisms for account-wide AI behavior patterns
