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
- [x] Helper scripts (copy-*, cleanup-*, remux-only, remux-select-audio): see README
- [x] Test suite (legacy + bats); see README for how to run
- [x] Second pass transcoding: Automatically performs a second transcoding pass with adjusted quality if the first pass bitrate is outside tolerance range
- [x] Preprocessing pass for non-QuickLook formats: Automatically remuxes non-QuickLook compatible files (mkv, wmv, avi, webm, flv) that are within tolerance or below target, including `.orig.` files, before main file discovery
- [x] Codec compatibility checking: Checks codec compatibility before remuxing to prevent failures with incompatible codecs (e.g., WMV3)
- [x] Command-line target bitrate override: Added `--target-bitrate` (or `-t`) flag to override resolution-based target bitrate for all files
- [x] Configurable subdirectory depth: Added `-L` and `--max-depth` command-line flags for configurable directory traversal depth (default: 2, supports unlimited with `-L 0`)
- [x] Third pass with linear interpolation: Automatically performs a third transcoding pass using linear interpolation between first and second pass data points when second pass is still outside tolerance, addressing overcorrection issues

### Implementation Notes (Known Issues)

- **macOS-only**: Currently only supports macOS due to VideoToolbox. Cross-platform may be considered later.
- **No iteration limit**: Optimization loop runs until convergence or quality bounds (0–100); no fixed cap.
- **FFmpeg process cleanup**: Signal handling kills process group on interrupt; behavior with input seeking may need verification.

*Recent changes and session history are in [CHANGELOG.md](CHANGELOG.md).*

## Future Enhancements

### Smart Pre-processing

- [x] **Skip already optimized files**: Exit early if the source file is already within ±5% of the target bitrate for its resolution. This prevents unnecessary transcoding when the file is already optimized. (Implemented)
- [x] **MKV remuxing for optimized files**: For MKV files that are already within tolerance or below target bitrate, automatically remux them to MP4 with QuickLook compatibility. This converts the container format without transcoding video/audio streams, improving macOS Finder QuickLook compatibility while preserving quality. Uses `-movflags +faststart` and `-tag:v hvc1` (for HEVC) for optimal QuickLook support. (Implemented)
- [ ] **Initial pass to identify work**: Perform an initial pass over all discovered video files to capture all potential work and allow short-circuiting logic to filter down to untranscoded files before starting any transcoding. This prevents non-deterministic behavior where a file transcoded close to the target bitrate (but slightly out of tolerance) causes a second run of the script to attempt re-encoding an already good enough encoded file. The initial pass would identify files that are already within tolerance or have encoded versions, ensuring they are properly skipped before any transcoding begins.
- [x] **Single-pass remux and transcode**: Ensure that both the remuxing pass and transcoding pass happen in a single script execution, rather than requiring two separate runs. (Implemented.) The current design already achieves this: preprocessing only remuxes (or compatibility-transcodes) files that are within tolerance or below target; those outputs use `.orig.` naming and need no further work. Above-target non-QuickLook files are not touched in preprocessing—they are found by `find_all_video_files()` (called after preprocessing) and transcoded in the main loop in one pass. No second run is required.
- [ ] **Revisit start-of-run output**: Revisit the output at the start of the script when it calculates the collection of work to do. Address pre-processing message ordering, the "Found X video file(s) to process" summary, and noisy repeated lines (e.g. "Target bitrate" logged once per file during pre-processing when that phase runs over many non-QuickLook files). Goal: clearer, less repetitive initial output so the user sees a coherent picture of what will be done before processing begins.
- [ ] **Run once: remux then reencode (re-invoke)**: Simple implementation where the remux path, after finishing, calls the script itself again so one user run yields both remuxing and reencoding. Base case: when the script is run *after* a remux, it must not run the remux/preprocess step again. The recursive call passes a post-remux indicator (e.g. env var `BOILER_AFTER_REMUX=1` or flag `--after-remux`). First run: run remux/preprocess; when that pass finishes, re-exec the script with the indicator. Second run: if the indicator is set, skip remux/preprocess and only do discovery + transcode; do not set the indicator again, so no third run. Result: one user invocation → one remux pass then one encode pass.

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
  - **Helper script consistency**: Updated `cleanup-originals.sh` and `remux-only.sh` to support the same depth traversal capability
  This provides flexibility for users with deeply nested directory structures while maintaining the current default behavior. (Implemented)
- [x] **Predictable file processing order**: Iterate over files in a predictable order (e.g., alphabetical) to ensure consistent behavior across runs and make batch processing more deterministic. (Implemented: `find_all_video_files()` and `find_skipped_video_files()` output sorted via `sort`; `preprocess_non_quicklook_files()` sorts its file list before iterating.)

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
- [ ] **Force flag to bypass file skipping**: Add a `--force` or `-f` flag that allows processing files that would normally be skipped due to filename markers (`.fmpg.`, `.orig.`, `.hbrk.`). This would enable re-processing already transcoded files when needed (e.g., to re-encode with different settings, fix encoding issues, or update files with new encoding parameters). Implementation considerations:
  - **Command-line flag**: Add `-f` or `--force` flag to bypass `should_skip_file()` checks
  - **Skip logic modification**: Update `find_all_video_files()` and file processing logic to respect the force flag
  - **Safety considerations**: The force flag should still respect encoded version checks (e.g., if both original and encoded exist, force should allow processing the encoded version)
  - **Use cases**: 
    - Re-encoding files with updated target bitrates or quality settings
    - Fixing encoding issues or artifacts in previously transcoded files
    - Updating files to use newer encoding parameters or codec versions
    - Processing files that were incorrectly marked or need re-processing
  - **Warning message**: When force flag is used, display a clear warning that already-processed files will be re-processed
  - **Documentation**: Update help text to explain the force flag and its use cases
  This would provide flexibility for edge cases where re-processing is needed while maintaining the default safe behavior of skipping already-processed files.
- [ ] **Remuxed-but-never-transcoded vs. cleanup-originals**: Edge case: some files get remuxed in preprocessing (or by remux-only.sh) but are never transcoded (e.g. they are at/below target so they only get remuxed with `.orig.` naming). If a remuxed file ever does not get the `.orig.` marker (e.g. wrong output path, or a different tool), or if the remuxed file ends up in a different directory than the original, then when the user runs cleanup-originals on that directory, the file can be deleted because it has no transcoding markers and no companion transcoded file. Implementation considerations:
  - **boiler.sh**: Ensure every remuxed output always has `.orig.` in the filename and is written in the same directory as the source (e.g. `handle_non_quicklook_at_target` should prepend `dirname` to the output path so subdirectory sources produce subdirectory outputs).
  - **cleanup-originals**: Optionally, only treat a file as "original" (candidate for deletion) if there is an encoded/remuxed companion in the same directory (e.g. same base name with `.fmpg.`, `.orig.`, or `.hbrk.`), so that remux-only directories are not over-cleaned. Alternatively, document that remuxed files must always carry the `.orig.` marker so cleanup-originals correctly skips them.

### Quality Control and Optimization

- [x] **Command-line bitrate override**: Add command-line argument support (e.g., `--target-bitrate 6.5`) to override the resolution-based target bitrate. The `transcode_video()` function already supports an optional target bitrate override parameter, so this would primarily involve adding argument parsing to the main script entry point. This would enable users to specify custom bitrates for specific transcoding operations without modifying the script. (Implemented - supports `--target-bitrate` and `-t` flags, applies to all files, validates bitrate values between 0.1 and 100 Mbps)
- [ ] **Aspect ratio corner case handling**: Handle edge cases where files are effectively 1080p or 4K resolution but the current height-based detection picks a lower resolution target due to unusual aspect ratios (very narrow/wide videos). For example, a 2160x1080 (2:1 ultrawide) video would currently be detected as 1080p based on height, but it's effectively 4K content. Implementation considerations:
  - **Dual-dimension checking**: Use both height and width to determine resolution tier
  - **Approach options**:
    - Check if width meets the threshold even if height doesn't (e.g., 3840 width = 4K even if height is 1080)
    - Use the larger dimension (max of width/height) to determine resolution tier
    - Check both dimensions and use the higher tier that either dimension qualifies for
  - **Resolution thresholds**: 
    - 4K: height ≥2160 OR width ≥3840
    - 1080p: height ≥1080 OR width ≥1920 (but not 4K)
    - 720p: height ≥720 OR width ≥1280 (but not 1080p/4K)
    - 480p: height ≥480 OR width ≥854 (but not higher tiers)
  - **Implementation**: Update `get_video_resolution()` to extract both width and height, then modify `calculate_target_bitrate()` to use dual-dimension logic
  - **Backward compatibility**: Ensure standard 16:9 videos continue to work as expected
  This would ensure that ultrawide, portrait, or other non-standard aspect ratio videos get appropriate bitrate targets based on their actual content resolution rather than just height.
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

### CLI Subcommand Architecture

- [ ] **Subcommand interface for individual operations**: The modular architecture of `boiler.sh` decomposes naturally into individual subcommands (discover, analyze, transcode, etc.) that could be exposed via CLI, enabling granular control and scripting use cases. Based on the functional unit decomposition documented in `docs/ARCHITECTURE.md`.
  
  **See [plans/SUBCOMMAND-INTERFACE-PLAN.md](plans/SUBCOMMAND-INTERFACE-PLAN.md)** for detailed implementation specifications including all 8 proposed subcommands, exit codes, global variable handling strategy, signal handling considerations, and 5-phase implementation plan.

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

- [x] **Test suite refactoring for speed and independence**: Implemented dual test suite strategy with bats-core framework.
  - **Legacy suite** (`test_boiler.sh`): 271 tests, ~6s, quick feedback during development
  - **Bats suite** (`tests/*.bats`): 217 tests, ~16s parallel, thorough pre-commit verification with proper isolation
  - **Recommended workflow**: Run legacy for rapid iteration, bats before commits
  - **Both suites**: Use same mocking approach, work without FFmpeg/ffprobe, comprehensive coverage
- [ ] **Account-wide Cursor configuration for "remember what you need to" convention**: Explore options for making the PROJECT-CONTEXT.md/PLAN.md/README.md update convention reusable across projects. Options to investigate:
  - Custom command template in `~/.cursor/command-templates/` that can be copied to each project's `.cursor/commands/` directory
  - Global `.cursorrules` file in home directory (`~/.cursorrules`) if Cursor supports account-wide rules
  - Other Cursor configuration mechanisms for account-wide AI behavior patterns
