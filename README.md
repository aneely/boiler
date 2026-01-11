# Boiler - Video Transcoding Tool

A simplified command-line tool for transcoding video files with automatic quality optimization. Boiler automatically finds the optimal encoding settings to achieve target bitrates while maintaining quality.

## Features

- 🎯 **Automatic bitrate targeting** - Sets target bitrates based on video resolution
- 🔍 **Quality optimization** - Iteratively finds optimal bitrate settings to hit target bitrates
- 🚀 **Hardware acceleration** - Uses Apple VideoToolbox for fast encoding on macOS
- 📊 **Progress feedback** - Color-coded output with clear status messages
- ⚡ **Fast iteration** - Uses adaptive multi-point sampling (1-3 samples per iteration based on video length) to quickly find optimal settings
- ✨ **Smart pre-processing** - Automatically skips transcoding if source video is already within target bitrate tolerance, remuxes non-QuickLook compatible files (mkv, wmv, avi, webm, flv) to MP4 for QuickLook compatibility when appropriate, and skips already-encoded files automatically. Includes codec compatibility checking to prevent remux failures.

## Current Defaults

- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (Apple VideoToolbox hardware acceleration)
- **Container**: MP4
- **Quality control**: Constant quality mode (`-q:v`) - Iteratively adjusts quality value (0-100, higher = higher quality/bitrate) to hit target bitrate
- **Audio**: Copy (no re-encoding)
- **Target Bitrates**:
  - 2160p (4K): 11 Mbps
  - 1080p (Full HD): 8 Mbps
  - 720p (HD): 5 Mbps
  - 480p (SD): 2.5 Mbps
- **Platform**: Optimized for macOS Sequoia

## Requirements

- **macOS** - This tool is currently macOS-only (optimized for macOS Sequoia)
- **ffmpeg** - Video encoding/transcoding
- **ffprobe** - Video analysis (usually included with ffmpeg)
- **bc** - Calculator for bitrate computations

### Installing Dependencies

**macOS (Homebrew):**
```bash
brew install ffmpeg
```

Note: `bc` is typically pre-installed on macOS. If not available, install with:
```bash
brew install bc
```

## Usage

### Basic Usage

1. Navigate to the directory containing your video file:
   ```bash
   cd /path/to/video/directory
   ```

2. Run the script:
   ```bash
   ./boiler.sh
   ```

   Or with a custom target bitrate override:
   ```bash
   ./boiler.sh --target-bitrate 9.5
   ```

3. The script will:
   - Find all video files in the current directory and subdirectories (one level deep)
   - Automatically skip files that are already encoded (contain `.fmpg.`, `.orig.`, or `.hbrk.` markers) or have encoded versions in the same directory
   - Process each video file found
   - For each video:
     - Analyze its resolution and duration
     - Determine the target bitrate
     - Check if source video is already within ±5% of target (exits early if so)
     - Iteratively find the optimal quality setting by sampling from multiple points (if needed)
     - Transcode the full video
     - Output: `{base}.fmpg.{actual_bitrate}.Mbps.{ext}` (e.g., `video.fmpg.10.25.Mbps.mp4`)

### Command-Line Options

- `-t, --target-bitrate RATE` - Override target bitrate for all files (Mbps)
  - Example: `./boiler.sh --target-bitrate 9.5`
  - Applies the specified bitrate to all videos regardless of resolution
  - Accepts decimal values (e.g., `9.5` for 9.5 Mbps)
  - Must be between 0.1 and 100 Mbps

- `-h, --help` - Show usage information and exit

### Example Output

```
[INFO] Found video file: my_video.mp4
[INFO] Video resolution: 2160p
[INFO] Target bitrate: 11 Mbps (2160p)
[INFO] Using constant quality mode (-q:v), sampling from multiple points to find optimal quality setting
[INFO] Iteration 1: Testing with quality=52
[INFO] Average bitrate from 3 samples: 12.5 Mbps
[INFO] Actual bitrate too high, decreasing quality from 52 to 48
[INFO] Iteration 2: Testing with quality=48
[INFO] Average bitrate from 3 samples: 10.8 Mbps
[INFO] Bitrate is within acceptable range (5% of target)
[INFO] Optimal quality setting found: 48 (higher = higher quality/bitrate)
[INFO] Starting full video transcoding with constant quality mode...
[INFO] Transcoding complete!
[INFO] Output file: my_video.fmpg.10.80.Mbps.mp4
```

## How It Works

The script follows a modular architecture with focused functions for each step:

1. **Discovery**: Finds all video files in the current directory and subdirectories (one level deep), automatically skipping files that are already encoded (contain `.fmpg.`, `.orig.`, or `.hbrk.` markers) or have encoded versions in the same directory
2. **Analysis**: Uses `ffprobe` to determine video resolution and duration for each file
3. **Targeting**: Sets target bitrate based on resolution
4. **Pre-check**: Checks if source video is already within ±5% of target bitrate (exits early if so)
5. **Optimization** (if needed): 
   - Samples from multiple points (beginning ~10%, middle ~50%, end ~90% for videos ≥180s; fewer samples for shorter videos)
   - Transcodes 60-second samples at different quality settings (using constant quality mode `-q:v`)
   - Averages bitrates from all samples
   - Adjusts quality value (0-100) proportionally until actual output matches target (±5% tolerance)
   - Continues until convergence, oscillation detection, or quality bounds reached
6. **Encoding**: Transcodes the full video using the optimal quality setting
7. **Second pass** (if needed): If the first pass bitrate is outside tolerance, automatically performs a second transcoding pass with an adjusted quality value to get closer to the target bitrate

The script is organized into modular functions for maintainability and clarity. All values are sanitized to prevent calculation errors, and logging output is properly separated from function return values. The codebase has been refactored to eliminate duplication with shared helper functions for bitrate measurement, tolerance checking, and value sanitization.

## Supported Video Formats

The tool automatically detects these video file extensions:
- MP4 (`.mp4`)
- MKV (`.mkv`)
- AVI (`.avi`)
- MOV (`.mov`)
- M4V (`.m4v`)
- WebM (`.webm`)
- FLV (`.flv`)
- WMV (`.wmv`)

## Limitations

- **macOS-only** - Currently only supports macOS (VideoToolbox hardware acceleration requires macOS)
- Processes video files in current directory and subdirectories one level deep (not recursive)
- Uses hardcoded defaults (not yet configurable)
- Audio is always copied (not re-encoded)

## Future Features

See [PLAN.md](PLAN.md) for the complete roadmap. Upcoming features include:

- 🎛️ **Enhanced command-line options** - Resolution-specific bitrate overrides (e.g., `-t 2160p=9,1080p=5`), config file support
- 📊 **Enhanced output modes** - Verbose/quiet modes, dry-run (basic progress indicators already exist)
- ⚙️ **Configuration system** - Customize default bitrates, codecs, and containers
  - Configurable target bitrates per resolution (2160p, 1080p, 720p, 480p)
  - SDR vs HDR bitrate differentiation (separate bitrates for Standard Dynamic Range and High Dynamic Range content)
- 📦 **Installation** - Install as a system command, run from any directory
- 🌐 **Cross-platform support** - Port to Linux/Windows (currently macOS-only)

## Troubleshooting

### "ffmpeg is not installed or not in PATH"
Install ffmpeg using Homebrew:
```bash
brew install ffmpeg
```

### "No video file found in current directory"
Make sure you're in the directory containing the video file, or that the video file has a supported extension.

### "Could not determine video resolution"
The video file may be corrupted or in an unsupported format. Try checking the file with `ffprobe` directly:
```bash
ffprobe your_video.mp4
```

### Transcoding takes a long time
This is normal for high-resolution videos. The script uses hardware acceleration via VideoToolbox, which is significantly faster than software encoding. The optimization phase samples from multiple points, which may take a few minutes, but ensures accurate bitrate targeting.

### Optimization takes many iterations
The script uses an iterative approach to find the optimal quality setting. It continues until convergence (bitrate within ±5% tolerance), oscillation detection, or quality bounds are reached. If optimization seems to be taking too long, the video may have highly variable complexity, or the target bitrate may be difficult to achieve. The script will automatically detect and handle oscillation between quality values.

### Parse errors or calculation issues
The script includes value sanitization to prevent calculation errors. If you encounter parse errors, ensure that `bc` is properly installed and that video file metadata is readable. The script automatically cleans values before calculations to handle edge cases.

### Helper Scripts

For testing and development, helper scripts are available:

- **`./copy-1080p-test.sh`** - Copies the 1080p test video to the current directory
- **`./copy-4k-test.sh`** - Copies the 4K test video to the current directory  
- **`./cleanup-mp4.sh`** - Removes all .mp4 files from the project root directory

### Running Tests

The project includes a comprehensive test suite (`test_boiler.sh`) with 183 tests covering utility functions, mocked FFmpeg/ffprobe functions, and full integration tests (including second pass transcoding scenarios, multiple resolution support, `calculate_adjusted_quality()` unit tests, codec compatibility checking, and error handling tests). The test suite uses function mocking to avoid requiring actual video files or FFmpeg installation, making it suitable for CI/CD environments.

To run the test suite:
```bash
bash test_boiler.sh
```

The tests verify function behavior through call tracking rather than file side effects, ensuring fast execution and reliable results.

## Contributing

This is an early-stage project. Contributions and feedback are welcome!

## License

See individual file headers for license information. Test videos are licensed under Creative Commons Attribution (see `testdata/video-attribution-cc-license.txt`).

## Code Structure

The script is organized into modular functions for better maintainability:

- **Utility functions**: Video discovery, resolution/duration detection, requirement checking
- **Configuration functions**: Target bitrate calculation, sample point calculation
- **Transcoding functions**: Sample transcoding, bitrate measurement, optimization loop, full video transcoding
- **Main orchestration**: The `main()` function coordinates all steps

This modular structure makes the code easier to understand, test, and maintain. For detailed technical information, see [PROJECT-CONTEXT.md](PROJECT-CONTEXT.md).

## Related Documentation

- [PROJECT-CONTEXT.md](PROJECT-CONTEXT.md) - Technical details, architecture, and design decisions
- [PLAN.md](PLAN.md) - Development roadmap and future features

