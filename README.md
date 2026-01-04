# Boiler - Video Transcoding Tool

A simplified command-line tool for transcoding video files with automatic quality optimization. Boiler automatically finds the optimal encoding settings to achieve target bitrates while maintaining quality.

## Features

- 🎯 **Automatic bitrate targeting** - Sets target bitrates based on video resolution
- 🔍 **Quality optimization** - Iteratively finds optimal bitrate settings to hit target bitrates
- 🚀 **Hardware acceleration** - Uses Apple VideoToolbox for fast encoding on macOS
- 📊 **Progress feedback** - Color-coded output with clear status messages
- ⚡ **Fast iteration** - Uses multi-point sampling (3 samples per iteration) to quickly find optimal settings

## Current Defaults

- **Codec**: HEVC (H.265) via `hevc_videotoolbox` (Apple VideoToolbox hardware acceleration)
- **Container**: MP4
- **Quality control**: Bitrate mode (VideoToolbox doesn't support CRF)
- **Audio**: Copy (no re-encoding)
- **Target Bitrates**:
  - 2160p (4K): 11 Mbps
  - 1080p (Full HD): 8 Mbps
- **Platform**: Optimized for macOS Sequoia

## Requirements

- **ffmpeg** - Video encoding/transcoding
- **ffprobe** - Video analysis (usually included with ffmpeg)
- **bc** - Calculator for bitrate computations

### Installing Dependencies

**macOS (Homebrew):**
```bash
brew install ffmpeg
```

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install ffmpeg bc
```

**Fedora/RHEL:**
```bash
sudo dnf install ffmpeg bc
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

3. The script will:
   - Find the video file in the current directory
   - Analyze its resolution and duration
   - Determine the target bitrate
   - Iteratively find the optimal bitrate setting by sampling from multiple points
   - Transcode the full video
   - Output: `{original_name}_transcoded.mp4`

### Example Output

```
[INFO] Found video file: my_video.mp4
[INFO] Video resolution: 2160p
[INFO] Target bitrate: 11 Mbps (2160p)
[INFO] Starting quality adjustment process...
[INFO] Sampling from 3 points (beginning, middle, end) to find optimal bitrate setting
[INFO] Iteration 1: Testing with bitrate=11.00 Mbps (11000 kbps)
[INFO] Average bitrate from 3 samples: 12.5 Mbps
[INFO] Actual bitrate too high, decreasing bitrate setting from 11000k to 9900k
[INFO] Iteration 2: Testing with bitrate=9.90 Mbps (9900 kbps)
[INFO] Average bitrate from 3 samples: 10.8 Mbps
[INFO] Bitrate is within acceptable range (10% of target)
[INFO] Optimal bitrate setting found: 9900 kbps (9.90 Mbps)
[INFO] Starting full video transcoding...
[INFO] Transcoding complete!
[INFO] Output file: my_video_transcoded.mp4
```

## How It Works

1. **Discovery**: Finds the first video file in the current directory
2. **Analysis**: Uses `ffprobe` to determine video resolution and duration
3. **Targeting**: Sets target bitrate based on resolution
4. **Optimization**: 
   - Samples from 3 points (beginning ~10%, middle ~50%, end ~90%)
   - Transcodes 15-second samples at different bitrate settings
   - Averages bitrates from all 3 samples
   - Adjusts bitrate setting until actual output matches target (±10% tolerance)
   - Maximum 10 iterations, exits with error if not converged
5. **Encoding**: Transcodes the full video using the optimal bitrate setting

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

- Currently processes one video file per execution
- Must be run from the directory containing the video file
- Uses hardcoded defaults (not yet configurable)
- Audio is always copied (not re-encoded)
- Optimized for macOS - VideoToolbox hardware acceleration requires macOS
- VideoToolbox only supports bitrate mode, not CRF (quality-based encoding)

## Future Features

See [PLAN.md](PLAN.md) for the complete roadmap. Upcoming features include:

- 📁 **Batch processing** - Process multiple files at once
- 🎛️ **Command-line options** - Override defaults per-transcode
- 📊 **Enhanced output modes** - Progress indicators, verbose/quiet modes, dry-run
- ⚙️ **Configuration system** - Customize default bitrates, codecs, and containers
- 📦 **Installation** - Install as a system command, run from any directory

## Troubleshooting

### "ffmpeg is not installed or not in PATH"
Install ffmpeg using your system's package manager (see Requirements above).

### "No video file found in current directory"
Make sure you're in the directory containing the video file, or that the video file has a supported extension.

### "Could not determine video resolution"
The video file may be corrupted or in an unsupported format. Try checking the file with `ffprobe` directly:
```bash
ffprobe your_video.mp4
```

### Transcoding takes a long time
This is normal for high-resolution videos. The script uses hardware acceleration via VideoToolbox, which is significantly faster than software encoding. The optimization phase samples from multiple points, which may take a few minutes, but ensures accurate bitrate targeting.

### "Reached maximum iterations" error
If the script fails to converge within 10 iterations, it may indicate that the target bitrate is not achievable with the current settings, or there's an issue with the video file. Check that the video file is valid and not corrupted.

### Helper Scripts

For testing and development, helper scripts are available:

- **`./copy-1080p-test.sh`** - Copies the 1080p test video to the current directory
- **`./copy-4k-test.sh`** - Copies the 4K test video to the current directory  
- **`./cleanup-mp4.sh`** - Removes all .mp4 files from the project root directory

## Contributing

This is an early-stage project. Contributions and feedback are welcome!

## License

See individual file headers for license information. Test videos are licensed under Creative Commons Attribution (see `testdata/video-attribution-cc-license.txt`).

## Related Documentation

- [CONTEXT.md](CONTEXT.md) - Technical details and architecture
- [PLAN.md](PLAN.md) - Development roadmap and future features

