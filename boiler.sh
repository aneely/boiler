#!/bin/bash

# FFmpeg transcoding wrapper with automatic quality adjustment
# Transcodes video to target bitrate using HEVC via Apple VideoToolbox (hardware-accelerated)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages (to stderr so they don't interfere with function return values)
info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if required tools are available
check_requirements() {
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
}

# Find video files in current directory
find_video_file() {
    local video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv")
    local video_file=""

    for ext in "${video_extensions[@]}"; do
        local found=$(find . -maxdepth 1 -type f -iname "*.${ext}" | head -1)
        if [ -n "$found" ]; then
            video_file="$found"
            break
        fi
    done

    if [ -z "$video_file" ]; then
        error "No video file found in current directory"
        exit 1
    fi

    echo "$video_file"
}

# Get video resolution using ffprobe
get_video_resolution() {
    local video_file="$1"
    local resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null | head -1 | tr -d '\n\r')

    if [ -z "$resolution" ]; then
        error "Could not determine video resolution"
        exit 1
    fi

    echo "$resolution"
}

# Get video duration using ffprobe
get_video_duration() {
    local video_file="$1"
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null | head -1 | tr -d '\n\r')

    if [ -z "$duration" ]; then
        error "Could not determine video duration"
        exit 1
    fi

    echo "$duration"
}

# Calculate target bitrate based on resolution
# Returns: TARGET_BITRATE_MBPS TARGET_BITRATE_BPS (via global variables)
calculate_target_bitrate() {
    local resolution="$1"
    
    if [ "$resolution" -ge 2160 ]; then
        TARGET_BITRATE_MBPS=11
        TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
        info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (2160p)"
    elif [ "$resolution" -ge 1080 ]; then
        TARGET_BITRATE_MBPS=8
        TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
        info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (1080p)"
    else
        warn "Resolution ${resolution}p is below 1080p, using 1080p target bitrate (8 Mbps)"
        TARGET_BITRATE_MBPS=8
        TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
    fi
}

# Calculate sample points: beginning (10%), middle (50%), and end (90%)
# Returns: SAMPLE_START_1 SAMPLE_START_2 SAMPLE_START_3 (via global variables)
calculate_sample_points() {
    local video_duration="$1"
    local sample_duration=15
    
    # Clean video_duration for bc (remove any newlines/whitespace)
    video_duration=$(echo "$video_duration" | tr -d '\n\r')
    
    # Calculate initial sample points
    local sample_start_1=$(echo "scale=1; $video_duration * 0.1" | bc | tr -d '\n\r')
    local sample_start_2=$(echo "scale=1; $video_duration * 0.5" | bc | tr -d '\n\r')
    local sample_start_3=$(echo "scale=1; $video_duration * 0.9" | bc | tr -d '\n\r')
    
    # Ensure sample points don't exceed video duration
    local max_start=$(echo "scale=1; $video_duration - $sample_duration" | bc | tr -d '\n\r')
    if (( $(echo "$sample_start_1 > $max_start" | bc -l) )); then
        sample_start_1=0
    fi
    if (( $(echo "$sample_start_2 > $max_start" | bc -l) )); then
        sample_start_2=$max_start
    fi
    if (( $(echo "$sample_start_3 > $max_start" | bc -l) )); then
        sample_start_3=$max_start
    fi
    
    SAMPLE_START_1="$sample_start_1"
    SAMPLE_START_2="$sample_start_2"
    SAMPLE_START_3="$sample_start_3"
    SAMPLE_DURATION=$sample_duration
}

# Transcode a sample from a specific point in the video
transcode_sample() {
    local video_file="$1"
    local sample_start="$2"
    local sample_duration="$3"
    local bitrate_kbps="$4"
    local output_file="$5"
    
    ffmpeg -y -i "$video_file" \
        -ss "$sample_start" \
        -t $sample_duration \
        -c:v hevc_videotoolbox \
        -b:v ${bitrate_kbps}k \
        -c:a copy \
        -f mp4 \
        "$output_file" \
        -loglevel error -stats
}

# Measure bitrate from a sample file
measure_sample_bitrate() {
    local sample_file="$1"
    local sample_duration="$2"
    
    # Try to get bitrate from ffprobe first
    local bitrate_bps=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$sample_file" 2>/dev/null | head -1 | tr -d '\n\r')
    
    # If bitrate is not available, use file size calculation as fallback
    if [ -z "$bitrate_bps" ] || [ "$bitrate_bps" = "N/A" ]; then
        local file_size_bytes=$(stat -f%z "$sample_file" 2>/dev/null || stat -c%s "$sample_file" 2>/dev/null | tr -d '\n\r')
        # Ensure sample_duration is clean for bc
        sample_duration=$(echo "$sample_duration" | tr -d '\n\r')
        bitrate_bps=$(echo "scale=0; ($file_size_bytes * 8) / $sample_duration" | bc | tr -d '\n\r')
    fi
    
    if [ -n "$bitrate_bps" ] && [ "$bitrate_bps" != "N/A" ]; then
        echo "$bitrate_bps"
    else
        echo ""
    fi
}

# Find optimal bitrate setting through iterative sampling
find_optimal_bitrate() {
    local video_file="$1"
    local target_bitrate_bps="$2"
    local lower_bound="$3"
    local upper_bound="$4"
    local sample_start_1="$5"
    local sample_start_2="$6"
    local sample_start_3="$7"
    local sample_duration="$8"
    
    local bitrate_step_percent=10
    local max_iterations=10
    local iteration=0
    local target_bitrate_kbps=$((target_bitrate_bps / 1000))
    local test_bitrate_kbps=$target_bitrate_kbps
    
    info "Starting quality adjustment process..."
    info "Sampling from 3 points (beginning, middle, end) to find optimal bitrate setting"
    
    while [ $iteration -lt $max_iterations ]; do
        iteration=$((iteration + 1))
        local test_bitrate_mbps=$(echo "scale=2; $test_bitrate_kbps / 1000" | bc | tr -d '\n\r')
        info "Iteration $iteration: Testing with bitrate=${test_bitrate_mbps} Mbps (${test_bitrate_kbps} kbps)"
        
        # Sample from multiple points and average the bitrates
        local total_bitrate_bps=0
        local sample_count=0
        local sample_index=0
        
        for sample_start in "$sample_start_1" "$sample_start_2" "$sample_start_3"; do
            sample_index=$((sample_index + 1))
            local sample_file_point="${video_file%.*}_sample_${sample_index}.mp4"
            
            # Clean sample_start for use (remove any whitespace/newlines)
            sample_start=$(echo "$sample_start" | tr -d '\n\r' | xargs)
            
            # Transcode sample
            transcode_sample "$video_file" "$sample_start" "$sample_duration" "$test_bitrate_kbps" "$sample_file_point"
            
            # Measure bitrate
            local sample_bitrate_bps=$(measure_sample_bitrate "$sample_file_point" "$sample_duration")
            
            if [ -n "$sample_bitrate_bps" ]; then
                # Clean values for bc calculation (remove newlines, carriage returns, and trim whitespace)
                total_bitrate_bps=$(echo "$total_bitrate_bps" | tr -d '\n\r' | xargs)
                sample_bitrate_bps=$(echo "$sample_bitrate_bps" | tr -d '\n\r' | xargs)
                # Add bitrates using bc
                total_bitrate_bps=$(echo "$total_bitrate_bps + $sample_bitrate_bps" | bc | tr -d '\n\r' | xargs)
                sample_count=$((sample_count + 1))
            fi
            
            # Clean up sample file
            rm -f "$sample_file_point"
        done
        
        if [ $sample_count -eq 0 ]; then
            error "Could not determine bitrate from any samples"
            exit 1
        fi
        
        # Calculate average bitrate (clean values for bc)
        total_bitrate_bps=$(echo "$total_bitrate_bps" | tr -d '\n\r' | xargs)
        local actual_bitrate_bps
        local actual_bitrate_mbps
        if [ "$sample_count" -gt 0 ]; then
            actual_bitrate_bps=$(echo "scale=0; $total_bitrate_bps / $sample_count" | bc | tr -d '\n\r' | xargs)
            actual_bitrate_mbps=$(echo "scale=2; $actual_bitrate_bps / 1000000" | bc | tr -d '\n\r' | xargs)
        else
            error "Invalid sample_count for average calculation"
            exit 1
        fi
        info "Average bitrate from $sample_count samples: ${actual_bitrate_mbps} Mbps"
        
        # Check if within acceptable range (clean bounds for comparison)
        lower_bound=$(echo "$lower_bound" | tr -d '\n\r' | xargs)
        upper_bound=$(echo "$upper_bound" | tr -d '\n\r' | xargs)
        actual_bitrate_bps=$(echo "$actual_bitrate_bps" | tr -d '\n\r' | xargs)
        if (( $(echo "$actual_bitrate_bps >= $lower_bound" | bc -l) )) && \
           (( $(echo "$actual_bitrate_bps <= $upper_bound" | bc -l) )); then
            info "Bitrate is within acceptable range (10% of target)"
            break
        fi
        
        # Adjust bitrate setting based on actual output
        local old_bitrate_kbps=$test_bitrate_kbps
        if (( $(echo "$actual_bitrate_bps < $lower_bound" | bc -l) )); then
            # Actual bitrate too low, increase bitrate setting
            test_bitrate_kbps=$(echo "scale=0; $test_bitrate_kbps * (1 + $bitrate_step_percent / 100)" | bc | tr -d '\n\r' | xargs | cut -d. -f1)
            info "Actual bitrate too low, increasing bitrate setting from ${old_bitrate_kbps}k to ${test_bitrate_kbps}k"
        else
            # Actual bitrate too high, decrease bitrate setting
            test_bitrate_kbps=$(echo "scale=0; $test_bitrate_kbps * (1 - $bitrate_step_percent / 100)" | bc | tr -d '\n\r' | xargs | cut -d. -f1)
            if [ $test_bitrate_kbps -lt 100 ]; then
                test_bitrate_kbps=100  # Minimum 100 kbps
            fi
            info "Actual bitrate too high, decreasing bitrate setting from ${old_bitrate_kbps}k to ${test_bitrate_kbps}k"
        fi
    done
    
    if [ $iteration -ge $max_iterations ]; then
        error "Reached maximum iterations ($max_iterations). Failed to find optimal bitrate setting."
        exit 1
    fi
    
    echo "$test_bitrate_kbps"
}

# Transcode full video with optimal settings
transcode_full_video() {
    local video_file="$1"
    local output_file="$2"
    local bitrate_kbps="$3"
    
    ffmpeg -i "$video_file" \
        -c:v hevc_videotoolbox \
        -b:v ${bitrate_kbps}k \
        -c:a copy \
        -f mp4 \
        "$output_file" \
        -loglevel info -stats
}

# Clean up sample files
cleanup_samples() {
    local video_file="$1"
    rm -f "${video_file%.*}_sample"*.mp4
}

# Main function
main() {
    # Check requirements
    check_requirements
    
    # Find video file
    VIDEO_FILE=$(find_video_file)
    info "Found video file: $VIDEO_FILE"
    
    # Get video properties
    RESOLUTION=$(get_video_resolution "$VIDEO_FILE")
    info "Video resolution: ${RESOLUTION}p"
    
    VIDEO_DURATION=$(get_video_duration "$VIDEO_FILE")
    
    # Calculate target bitrate
    calculate_target_bitrate "$RESOLUTION"
    
    # Calculate acceptable bitrate range (within 10% of target)
    LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.9" | bc | tr -d '\n\r')
    UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.1" | bc | tr -d '\n\r')
    
    # Generate output filename
    OUTPUT_FILE="${VIDEO_FILE%.*}_transcoded.mp4"
    
    # Calculate sample points
    calculate_sample_points "$VIDEO_DURATION"
    
    # Find optimal bitrate
    OPTIMAL_BITRATE_KBPS=$(find_optimal_bitrate "$VIDEO_FILE" "$TARGET_BITRATE_BPS" "$LOWER_BOUND" "$UPPER_BOUND" "$SAMPLE_START_1" "$SAMPLE_START_2" "$SAMPLE_START_3" "$SAMPLE_DURATION")
    
    FINAL_BITRATE_MBPS=$(echo "scale=2; $OPTIMAL_BITRATE_KBPS / 1000" | bc | tr -d '\n\r')
    info "Optimal bitrate setting found: ${OPTIMAL_BITRATE_KBPS} kbps (${FINAL_BITRATE_MBPS} Mbps)"
    info "Starting full video transcoding..."
    
    # Transcode full video
    transcode_full_video "$VIDEO_FILE" "$OUTPUT_FILE" "$OPTIMAL_BITRATE_KBPS"
    
    # Clean up any remaining sample files
    cleanup_samples "$VIDEO_FILE"
    
    info "Transcoding complete!"
    info "Output file: $OUTPUT_FILE"
}

# Run main function
main

