#!/bin/bash

# FFmpeg transcoding wrapper with automatic quality adjustment
# Transcodes video to target bitrate using HEVC via Apple VideoToolbox (hardware-accelerated)

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

# VideoToolbox HEVC doesn't support CRF - it only supports bitrate mode
# We'll iterate on the bitrate setting to find one that produces our target bitrate
# Start with the target bitrate as our initial guess
TARGET_BITRATE_KBPS=$((TARGET_BITRATE_BPS / 1000))
TEST_BITRATE_KBPS=$TARGET_BITRATE_KBPS
BITRATE_STEP_PERCENT=10  # Adjust by 10% each iteration
MAX_ITERATIONS=10
ITERATION=0

# Get video duration to sample from multiple points
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null | head -1)
if [ -z "$VIDEO_DURATION" ]; then
    error "Could not determine video duration"
    exit 1
fi

# Calculate sample points: beginning (10%), middle (50%), and end (90%)
SAMPLE_DURATION=15
SAMPLE_START_1=$(echo "scale=1; $VIDEO_DURATION * 0.1" | bc)
SAMPLE_START_2=$(echo "scale=1; $VIDEO_DURATION * 0.5" | bc)
SAMPLE_START_3=$(echo "scale=1; $VIDEO_DURATION * 0.9" | bc)

# Ensure sample points don't exceed video duration
MAX_START=$(echo "scale=1; $VIDEO_DURATION - $SAMPLE_DURATION" | bc)
if (( $(echo "$SAMPLE_START_1 > $MAX_START" | bc -l) )); then
    SAMPLE_START_1=0
fi
if (( $(echo "$SAMPLE_START_2 > $MAX_START" | bc -l) )); then
    SAMPLE_START_2=$MAX_START
fi
if (( $(echo "$SAMPLE_START_3 > $MAX_START" | bc -l) )); then
    SAMPLE_START_3=$MAX_START
fi

info "Starting quality adjustment process..."
info "Sampling from 3 points (beginning, middle, end) to find optimal bitrate setting"

# Iterative bitrate adjustment
while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))
    TEST_BITRATE_MBPS=$(echo "scale=2; $TEST_BITRATE_KBPS / 1000" | bc)
    info "Iteration $ITERATION: Testing with bitrate=${TEST_BITRATE_MBPS} Mbps (${TEST_BITRATE_KBPS} kbps)"
    
    # Sample from multiple points and average the bitrates
    TOTAL_BITRATE_BPS=0
    SAMPLE_COUNT=0
    
    SAMPLE_INDEX=0
    for SAMPLE_START in "$SAMPLE_START_1" "$SAMPLE_START_2" "$SAMPLE_START_3"; do
        SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
        SAMPLE_FILE_POINT="${VIDEO_FILE%.*}_sample_${SAMPLE_INDEX}.mp4"
        
        # Transcode 15 seconds sample from this point using VideoToolbox hardware acceleration
        ffmpeg -y -i "$VIDEO_FILE" \
            -ss "$SAMPLE_START" \
            -t $SAMPLE_DURATION \
            -c:v hevc_videotoolbox \
            -b:v ${TEST_BITRATE_KBPS}k \
            -c:a copy \
            -f mp4 \
            "$SAMPLE_FILE_POINT" \
            -loglevel error -stats
        
        # Get actual bitrate of this sample
        SAMPLE_BITRATE_BPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$SAMPLE_FILE_POINT" 2>/dev/null | head -1)
        
        if [ -z "$SAMPLE_BITRATE_BPS" ] || [ "$SAMPLE_BITRATE_BPS" = "N/A" ]; then
            # If bitrate is not available, try alternative method using file size
            FILE_SIZE_BYTES=$(stat -f%z "$SAMPLE_FILE_POINT" 2>/dev/null || stat -c%s "$SAMPLE_FILE_POINT" 2>/dev/null)
            SAMPLE_BITRATE_BPS=$(echo "scale=0; ($FILE_SIZE_BYTES * 8) / $SAMPLE_DURATION" | bc)
        fi
        
        if [ -n "$SAMPLE_BITRATE_BPS" ] && [ "$SAMPLE_BITRATE_BPS" != "N/A" ]; then
            TOTAL_BITRATE_BPS=$(echo "$TOTAL_BITRATE_BPS + $SAMPLE_BITRATE_BPS" | bc)
            SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
        fi
        
        # Clean up this sample file
        rm -f "$SAMPLE_FILE_POINT"
    done
    
    if [ $SAMPLE_COUNT -eq 0 ]; then
        error "Could not determine bitrate from any samples"
        exit 1
    fi
    
    # Calculate average bitrate
    ACTUAL_BITRATE_BPS=$(echo "scale=0; $TOTAL_BITRATE_BPS / $SAMPLE_COUNT" | bc)
    ACTUAL_BITRATE_MBPS=$(echo "scale=2; $ACTUAL_BITRATE_BPS / 1000000" | bc)
    info "Average bitrate from $SAMPLE_COUNT samples: ${ACTUAL_BITRATE_MBPS} Mbps"
    
    # Check if within acceptable range
    if (( $(echo "$ACTUAL_BITRATE_BPS >= $LOWER_BOUND" | bc -l) )) && \
       (( $(echo "$ACTUAL_BITRATE_BPS <= $UPPER_BOUND" | bc -l) )); then
        info "Bitrate is within acceptable range (10% of target)"
        break
    fi
    
    # Adjust bitrate setting based on actual output
    OLD_BITRATE_KBPS=$TEST_BITRATE_KBPS
    if (( $(echo "$ACTUAL_BITRATE_BPS < $LOWER_BOUND" | bc -l) )); then
        # Actual bitrate too low, increase bitrate setting
        TEST_BITRATE_KBPS=$(echo "scale=0; $TEST_BITRATE_KBPS * (1 + $BITRATE_STEP_PERCENT / 100)" | bc | cut -d. -f1)
        info "Actual bitrate too low, increasing bitrate setting from ${OLD_BITRATE_KBPS}k to ${TEST_BITRATE_KBPS}k"
    else
        # Actual bitrate too high, decrease bitrate setting
        TEST_BITRATE_KBPS=$(echo "scale=0; $TEST_BITRATE_KBPS * (1 - $BITRATE_STEP_PERCENT / 100)" | bc | cut -d. -f1)
        if [ $TEST_BITRATE_KBPS -lt 100 ]; then
            TEST_BITRATE_KBPS=100  # Minimum 100 kbps
        fi
        info "Actual bitrate too high, decreasing bitrate setting from ${OLD_BITRATE_KBPS}k to ${TEST_BITRATE_KBPS}k"
    fi
done

if [ $ITERATION -ge $MAX_ITERATIONS ]; then
    error "Reached maximum iterations ($MAX_ITERATIONS). Failed to find optimal bitrate setting."
    exit 1
fi

FINAL_BITRATE_MBPS=$(echo "scale=2; $TEST_BITRATE_KBPS / 1000" | bc)
info "Optimal bitrate setting found: ${TEST_BITRATE_KBPS} kbps (${FINAL_BITRATE_MBPS} Mbps)"
info "Starting full video transcoding..."

# Transcode full video with optimal settings using VideoToolbox hardware acceleration
ffmpeg -i "$VIDEO_FILE" \
    -c:v hevc_videotoolbox \
    -b:v ${TEST_BITRATE_KBPS}k \
    -c:a copy \
    -f mp4 \
    "$OUTPUT_FILE" \
    -loglevel info -stats

# Clean up any remaining sample files
rm -f "${VIDEO_FILE%.*}_sample"*.mp4

info "Transcoding complete!"
info "Output file: $OUTPUT_FILE"

