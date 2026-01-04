#!/bin/bash

# FFmpeg transcoding wrapper with automatic quality adjustment
# Transcodes video to target bitrate using HEVC/x265 codec

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required tools are available
if ! command -v ffmpeg &> /dev/null; then
    error "ffmpeg is not installed or not in PATH"
    exit 1
fi

if ! command -v ffprobe &> /dev/null; then
    error "ffprobe is not installed or not in PATH"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    error "bc is not installed or not in PATH (required for bitrate calculations)"
    exit 1
fi

# Find video files in current directory
# Common video extensions
VIDEO_EXTENSIONS=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv")
VIDEO_FILE=""

for ext in "${VIDEO_EXTENSIONS[@]}"; do
    found=$(find . -maxdepth 1 -type f -iname "*.${ext}" | head -1)
    if [ -n "$found" ]; then
        VIDEO_FILE="$found"
        break
    fi
done

if [ -z "$VIDEO_FILE" ]; then
    error "No video file found in current directory"
    exit 1
fi

info "Found video file: $VIDEO_FILE"

# Get video resolution using ffprobe
RESOLUTION=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null | head -1)

if [ -z "$RESOLUTION" ]; then
    error "Could not determine video resolution"
    exit 1
fi

info "Video resolution: ${RESOLUTION}p"

# Set target bitrate based on resolution
if [ "$RESOLUTION" -ge 2160 ]; then
    TARGET_BITRATE_MBPS=11
    TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
    info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (2160p)"
elif [ "$RESOLUTION" -ge 1080 ]; then
    TARGET_BITRATE_MBPS=8
    TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
    info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (1080p)"
else
    warn "Resolution ${RESOLUTION}p is below 1080p, using 1080p target bitrate (8 Mbps)"
    TARGET_BITRATE_MBPS=8
    TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
fi

# Calculate acceptable bitrate range (within 10% of target)
LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.9" | bc)
UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.1" | bc)

# Generate output filename
OUTPUT_FILE="${VIDEO_FILE%.*}_transcoded.mp4"
SAMPLE_FILE="${VIDEO_FILE%.*}_sample.mp4"

# Initial CRF value (lower = higher quality, higher bitrate)
# Start with a reasonable default for x265
CRF=23
CRF_STEP=1
MAX_ITERATIONS=20
ITERATION=0

info "Starting quality adjustment process..."
info "Transcoding 15-second sample to find optimal quality setting"

# Iterative quality adjustment
while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))
    info "Iteration $ITERATION: Testing with CRF=$CRF"
    
    # Transcode 15 seconds sample
    ffmpeg -y -i "$VIDEO_FILE" \
        -t 15 \
        -c:v libx265 \
        -preset medium \
        -crf $CRF \
        -c:a copy \
        -f mp4 \
        "$SAMPLE_FILE" \
        -loglevel error -stats
    
    # Get actual bitrate of sample
    ACTUAL_BITRATE_BPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$SAMPLE_FILE" 2>/dev/null | head -1)
    
    if [ -z "$ACTUAL_BITRATE_BPS" ] || [ "$ACTUAL_BITRATE_BPS" = "N/A" ]; then
        # If bitrate is not available, try alternative method using file size
        FILE_SIZE_BYTES=$(stat -f%z "$SAMPLE_FILE" 2>/dev/null || stat -c%s "$SAMPLE_FILE" 2>/dev/null)
        DURATION_SECONDS=15
        ACTUAL_BITRATE_BPS=$(echo "scale=0; ($FILE_SIZE_BYTES * 8) / $DURATION_SECONDS" | bc)
    fi
    
    ACTUAL_BITRATE_MBPS=$(echo "scale=2; $ACTUAL_BITRATE_BPS / 1000000" | bc)
    info "Actual bitrate: ${ACTUAL_BITRATE_MBPS} Mbps"
    
    # Check if within acceptable range
    if (( $(echo "$ACTUAL_BITRATE_BPS >= $LOWER_BOUND" | bc -l) )) && \
       (( $(echo "$ACTUAL_BITRATE_BPS <= $UPPER_BOUND" | bc -l) )); then
        info "Bitrate is within acceptable range (10% of target)"
        break
    fi
    
    # Adjust CRF based on bitrate
    if (( $(echo "$ACTUAL_BITRATE_BPS < $LOWER_BOUND" | bc -l) )); then
        # Bitrate too low, decrease CRF (higher quality)
        OLD_CRF=$CRF
        CRF=$((CRF - CRF_STEP))
        if [ $CRF -lt 0 ]; then
            CRF=0
        fi
        info "Bitrate too low, decreasing CRF from $OLD_CRF to $CRF"
    else
        # Bitrate too high, increase CRF (lower quality)
        OLD_CRF=$CRF
        CRF=$((CRF + CRF_STEP))
        if [ $CRF -gt 51 ]; then
            CRF=51
        fi
        info "Bitrate too high, increasing CRF from $OLD_CRF to $CRF"
    fi
    
    # Clean up sample file for next iteration
    rm -f "$SAMPLE_FILE"
done

if [ $ITERATION -ge $MAX_ITERATIONS ]; then
    warn "Reached maximum iterations. Using CRF=$CRF"
fi

info "Optimal CRF value found: $CRF"
info "Starting full video transcoding..."

# Transcode full video with optimal settings
ffmpeg -i "$VIDEO_FILE" \
    -c:v libx265 \
    -preset medium \
    -crf $CRF \
    -c:a copy \
    -f mp4 \
    "$OUTPUT_FILE" \
    -loglevel info -stats

# Clean up sample file
rm -f "$SAMPLE_FILE"

info "Transcoding complete!"
info "Output file: $OUTPUT_FILE"

