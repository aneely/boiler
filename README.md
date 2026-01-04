# Boiler - Video Transcoding Tool

A simplified command-line tool for transcoding video files with automatic quality optimization. Boiler automatically finds the optimal encoding settings to achieve target bitrates while maintaining quality.

## Features

- 🎯 **Automatic bitrate targeting** - Sets target bitrates based on video resolution
- 🔍 **Quality optimization** - Iteratively finds optimal CRF values to hit target bitrates
- 🎬 **Smart defaults** - Uses HEVC/x265 codec with sensible presets
- 📊 **Progress feedback** - Color-coded output with clear status messages
- ⚡ **Fast iteration** - Uses 15-second samples to quickly find optimal settings

## Current Defaults

- **Codec**: HEVC (H.265) via `libx265`
- **Container**: MP4
- **Preset**: `medium`
- **Audio**: Copy (no re-encoding)
- **Target Bitrates**:
  - 2160p (4K): 11 Mbps
  - 1080p (Full HD): 8 Mbps

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
   - Analyze its resolution
   - Determine the target bitrate
   - Iteratively find the optimal CRF value
   - Transcode the full video
   - Output: `{original_name}_transcoded.mp4`

### Example Output

```
[INFO] Found video file: my_video.mp4
[INFO] Video resolution: 2160p
[INFO] Target bitrate: 11 Mbps (2160p)
[INFO] Starting quality adjustment process...
[INFO] Transcoding 15-second sample to find optimal quality setting
[INFO] Iteration 1: Testing with CRF=23
[INFO] Actual bitrate: 12.5 Mbps
[INFO] Bitrate too high, increasing CRF from 23 to 24
[INFO] Iteration 2: Testing with CRF=24
[INFO] Actual bitrate: 10.8 Mbps
[INFO] Bitrate is within acceptable range (10% of target)
[INFO] Optimal CRF value found: 24
[INFO] Starting full video transcoding...
[INFO] Transcoding complete!
[INFO] Output file: my_video_transcoded.mp4
```

## How It Works

1. **Discovery**: Finds the first video file in the current directory
2. **Analysis**: Uses `ffprobe` to determine video resolution
3. **Targeting**: Sets target bitrate based on resolution
4. **Optimization**: Transcodes 15-second samples at different CRF values until target bitrate is achieved (±10% tolerance)
5. **Encoding**: Transcodes the full video using the optimal CRF value

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
This is normal for high-resolution videos. The script uses the `medium` preset which balances quality and speed. For faster encoding (with lower quality), you could modify the preset in the script, but this is not yet configurable.

## Contributing

This is an early-stage project. Contributions and feedback are welcome!

## License

See individual file headers for license information. Test videos are licensed under Creative Commons Attribution (see `testdata/video-attribution-cc-license.txt`).

## Related Documentation

- [CONTEXT.md](CONTEXT.md) - Technical details and architecture
- [PLAN.md](PLAN.md) - Development roadmap and future features

