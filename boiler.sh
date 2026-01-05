#!/bin/bash

# FFmpeg transcoding wrapper with automatic quality adjustment
# Transcodes video using constant quality mode (-q:v) with HEVC via Apple VideoToolbox (hardware-accelerated)
# Iteratively adjusts quality setting to achieve target bitrate

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Cleanup function: kill entire process group on exit/interrupt
# This automatically kills all child processes (including FFmpeg) without tracking PIDs
# The -- -$$ syntax means "kill process group of $$ (our PID)"
cleanup_on_exit() {
    # Kill the entire process group (all child processes)
    kill -- -$$ 2>/dev/null || true
    # Also clean up sample files if VIDEO_FILE is set
    if [ -n "${VIDEO_FILE:-}" ]; then
        rm -f "${VIDEO_FILE%.*}_sample"*.mp4 2>/dev/null || true
    fi
}

# Set up signal handlers to kill process group on exit/interrupt
trap cleanup_on_exit EXIT INT TERM

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

# Sanitize value for bc calculations (remove newlines, carriage returns, and trim whitespace)
sanitize_value() {
    echo "$1" | tr -d '\n\r' | xargs
}

# Measure bitrate from a video file
# Arguments: file_path, duration_seconds
# Returns: bitrate in bits per second, or empty string if unavailable
measure_bitrate() {
    local file_path="$1"
    local duration="$2"
    
    # Try to get bitrate from ffprobe first
    local bitrate_bps=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r')
    
    # If bitrate is not available, use file size calculation as fallback
    if [ -z "$bitrate_bps" ] || [ "$bitrate_bps" = "N/A" ]; then
        local file_size_bytes=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null | tr -d '\n\r')
        duration=$(sanitize_value "$duration")
        bitrate_bps=$(echo "scale=0; ($file_size_bytes * 8) / $duration" | bc | tr -d '\n\r')
    fi
    
    if [ -n "$bitrate_bps" ] && [ "$bitrate_bps" != "N/A" ]; then
        echo "$bitrate_bps"
    else
        echo ""
    fi
}

# Get source video bitrate
get_source_bitrate() {
    measure_bitrate "$1" "$2"
}

# Check if bitrate is within tolerance range
# Arguments: bitrate_bps, lower_bound_bps, upper_bound_bps
# Returns: 0 if within range, 1 otherwise
is_within_tolerance() {
    local bitrate_bps=$(sanitize_value "$1")
    local lower_bound=$(sanitize_value "$2")
    local upper_bound=$(sanitize_value "$3")
    
    if (( $(echo "$bitrate_bps >= $lower_bound" | bc -l) )) && \
       (( $(echo "$bitrate_bps <= $upper_bound" | bc -l) )); then
        return 0
    else
        return 1
    fi
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
# Adjusts sample positions for shorter videos that can't fit three non-overlapping samples
# Returns: SAMPLE_START_1 SAMPLE_START_2 SAMPLE_START_3 SAMPLE_COUNT (via global variables)
calculate_sample_points() {
    local video_duration="$1"
    local sample_duration=60
    
    # Clean video_duration for bc (remove any newlines/whitespace)
    video_duration=$(echo "$video_duration" | tr -d '\n\r')
    
    # If video is shorter than sample duration, use the whole video as the sample
    if (( $(echo "$video_duration < $sample_duration" | bc -l) )); then
        local sample_start_1=0
        local sample_start_2=""  # Empty means skip
        local sample_start_3=""  # Empty means skip
        
        SAMPLE_START_1="$sample_start_1"
        SAMPLE_START_2="$sample_start_2"
        SAMPLE_START_3="$sample_start_3"
        SAMPLE_COUNT=1
        SAMPLE_DURATION=$video_duration  # Use full video duration
        warn "Video duration (${video_duration}s) is shorter than standard sample duration (${sample_duration}s). Using entire video as sample."
        return
    fi
    
    local max_start=$(echo "scale=1; $video_duration - $sample_duration" | bc | tr -d '\n\r')
    local available_duration=$max_start
    
    # Determine how many samples we can fit and adjust positions accordingly
    # Need at least sample_duration between start positions to avoid overlap
    local min_spacing=$sample_duration
    local three_samples_space=$(echo "scale=1; $min_spacing * 2" | bc | tr -d '\n\r')
    
    if (( $(echo "$available_duration >= $three_samples_space" | bc -l) )); then
        # Video is long enough for three well-spaced samples (normal case)
        # Use standard positions: 10%, 50%, 90%
        local sample_start_1=$(echo "scale=1; $video_duration * 0.1" | bc | tr -d '\n\r')
        local sample_start_2=$(echo "scale=1; $video_duration * 0.5" | bc | tr -d '\n\r')
        local sample_start_3=$(echo "scale=1; $video_duration * 0.9" | bc | tr -d '\n\r')
        
        # Ensure sample points don't exceed max_start
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
        SAMPLE_COUNT=3
    elif (( $(echo "$available_duration >= $min_spacing" | bc -l) )); then
        # Video can fit two samples with proper spacing
        # Use beginning and end positions
        local sample_start_1=0
        local sample_start_2=$max_start
        local sample_start_3=""  # Empty means skip this sample
        
        SAMPLE_START_1="$sample_start_1"
        SAMPLE_START_2="$sample_start_2"
        SAMPLE_START_3="$sample_start_3"
        SAMPLE_COUNT=2
        warn "Video duration (${video_duration}s) allows only 2 samples instead of 3"
    else
        # Video can only fit one sample
        local sample_start_1=0
        local sample_start_2=""  # Empty means skip
        local sample_start_3=""  # Empty means skip
        
        SAMPLE_START_1="$sample_start_1"
        SAMPLE_START_2="$sample_start_2"
        SAMPLE_START_3="$sample_start_3"
        SAMPLE_COUNT=1
        warn "Video duration (${video_duration}s) allows only 1 sample instead of 3"
    fi
    
    SAMPLE_DURATION=$sample_duration
}

# Transcode a sample from a specific point in the video
# Uses input seeking (-ss before -i) for faster seeking performance
transcode_sample() {
    local video_file="$1"
    local sample_start="$2"
    local sample_duration="$3"
    local quality_value="$4"
    local output_file="$5"
    
    # Input seeking: -ss before -i makes seeking much faster, especially for later samples
    # -q:v: Constant quality mode (0-100, higher = higher quality/bitrate)
    ffmpeg -y -ss "$sample_start" \
        -i "$video_file" \
        -t $sample_duration \
        -c:v hevc_videotoolbox \
        -q:v ${quality_value} \
        -c:a copy \
        -movflags +faststart \
        -f mp4 \
        "$output_file" \
        -loglevel error -stats
}

# Measure bitrate from a sample file
measure_sample_bitrate() {
    measure_bitrate "$1" "$2"
}

# Find optimal quality setting through iterative sampling
# Uses constant quality mode (-q:v) and adjusts quality to hit target bitrate
find_optimal_quality() {
    local video_file="$1"
    local target_bitrate_bps="$2"
    local lower_bound="$3"
    local upper_bound="$4"
    local sample_start_1="$5"
    local sample_start_2="$6"
    local sample_start_3="$7"
    local sample_duration="$8"
    
    local min_step=1      # Minimum adjustment step (for fine-tuning when close)
    local max_step=10     # Maximum adjustment step (for large corrections when far off)
    local iteration=0
    # Start with a reasonable quality value
    # VideoToolbox -q:v scale: higher value = higher quality = higher bitrate
    # 52 is a good starting point
    local test_quality=52
    
    info "Starting quality adjustment process..."
    info "Using constant quality mode (-q:v), sampling from multiple points to find optimal quality setting"
    info "Using proportional adjustment algorithm (adjusts step size based on distance from target)"
    
    while true; do
        iteration=$((iteration + 1))
        info "Iteration $iteration: Testing with quality=${test_quality} (higher = higher quality/bitrate)"
        
        # Sample from multiple points and average the bitrates
        local total_bitrate_bps=0
        local sample_count=0
        local sample_index=0
        
        for sample_start in "$sample_start_1" "$sample_start_2" "$sample_start_3"; do
            # Skip empty sample positions (for shorter videos)
            if [ -z "$sample_start" ]; then
                continue
            fi
            
            sample_index=$((sample_index + 1))
            local sample_file_point="${video_file%.*}_sample_${sample_index}.mp4"
            
            # Clean sample_start for use
            sample_start=$(sanitize_value "$sample_start")
            
            # Transcode sample with quality setting
            transcode_sample "$video_file" "$sample_start" "$sample_duration" "$test_quality" "$sample_file_point"
            
            # Measure bitrate
            local sample_bitrate_bps=$(measure_sample_bitrate "$sample_file_point" "$sample_duration")
            
            if [ -n "$sample_bitrate_bps" ]; then
                # Clean values for bc calculation
                total_bitrate_bps=$(sanitize_value "$total_bitrate_bps")
                sample_bitrate_bps=$(sanitize_value "$sample_bitrate_bps")
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
        total_bitrate_bps=$(sanitize_value "$total_bitrate_bps")
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
        
        # Check if within acceptable range
        if is_within_tolerance "$actual_bitrate_bps" "$lower_bound" "$upper_bound"; then
            info "Bitrate is within acceptable range (10% of target)"
            break
        fi
        
        # Adjust quality setting based on actual output bitrate using proportional adjustment
        # VideoToolbox -q:v scale: higher value = higher quality = higher bitrate
        # Proportional adjustment: larger adjustments when far from target, smaller when close
        local old_quality=$test_quality
        local quality_adjustment=0
        local target_bitrate_mbps=$(echo "scale=2; $(sanitize_value "$target_bitrate_bps") / 1000000" | bc | tr -d '\n\r' | xargs)
        
        if (( $(echo "$actual_bitrate_bps < $lower_bound" | bc -l) )); then
            # Actual bitrate too low, need higher quality (increase quality value)
            # Calculate ratio: how far below target are we? (0.0 = at target, 0.5 = 50% of target, etc.)
            local ratio=$(echo "scale=4; $(sanitize_value "$actual_bitrate_bps") / $(sanitize_value "$target_bitrate_bps")" | bc | tr -d '\n\r')
            # Calculate adjustment: scale from min_step to max_step based on how far off we are
            # If ratio is 0.5 (50% of target), we want max_step adjustment
            # If ratio is 0.9 (90% of target), we want min_step adjustment
            # Formula: adjustment = min_step + (max_step - min_step) * (1 - ratio)
            local distance_from_target=$(echo "scale=4; 1 - $ratio" | bc | tr -d '\n\r')
            # Calculate adjustment and round to nearest integer
            local adjustment_float=$(echo "scale=4; $min_step + ($max_step - $min_step) * $distance_from_target" | bc | tr -d '\n\r')
            quality_adjustment=$(printf "%.0f" "$adjustment_float" | tr -d '\n\r' | xargs)
            # Ensure it's at least min_step
            if [ "$quality_adjustment" -lt "$min_step" ]; then
                quality_adjustment=$min_step
            fi
            
            test_quality=$((test_quality + quality_adjustment))
            if [ $test_quality -gt 100 ]; then
                test_quality=100  # Maximum quality value (highest quality/bitrate)
            fi
            info "Actual bitrate too low (${actual_bitrate_mbps} Mbps vs ${target_bitrate_mbps} Mbps target, ratio=${ratio}), increasing quality value from ${old_quality} to ${test_quality} (adjustment: +${quality_adjustment})"
        else
            # Actual bitrate too high, need lower quality (decrease quality value)
            # Calculate ratio: how far above target are we? (1.0 = at target, 2.0 = 200% of target, etc.)
            local ratio=$(echo "scale=4; $(sanitize_value "$actual_bitrate_bps") / $(sanitize_value "$target_bitrate_bps")" | bc | tr -d '\n\r')
            # Calculate adjustment: scale from min_step to max_step based on how far off we are
            # If ratio is 2.0 (200% of target), we want max_step adjustment
            # If ratio is 1.1 (110% of target), we want min_step adjustment
            # Formula: adjustment = min_step + (max_step - min_step) * (ratio - 1)
            local distance_from_target=$(echo "scale=4; $ratio - 1" | bc | tr -d '\n\r')
            # Cap distance at reasonable maximum (e.g., if ratio is 3.0, treat as 2.0 for adjustment calculation)
            if (( $(echo "$distance_from_target > 1.0" | bc -l) )); then
                distance_from_target=1.0
            fi
            # Calculate adjustment and round to nearest integer
            local adjustment_float=$(echo "scale=4; $min_step + ($max_step - $min_step) * $distance_from_target" | bc | tr -d '\n\r')
            quality_adjustment=$(printf "%.0f" "$adjustment_float" | tr -d '\n\r' | xargs)
            # Ensure it's at least min_step
            if [ "$quality_adjustment" -lt "$min_step" ]; then
                quality_adjustment=$min_step
            fi
            
            test_quality=$((test_quality - quality_adjustment))
            if [ $test_quality -lt 0 ]; then
                test_quality=0  # Minimum quality value (lowest quality/bitrate)
            fi
            info "Actual bitrate too high (${actual_bitrate_mbps} Mbps vs ${target_bitrate_mbps} Mbps target, ratio=${ratio}), decreasing quality value from ${old_quality} to ${test_quality} (adjustment: -${quality_adjustment})"
        fi
    done
    
    echo "$test_quality"
}

# Transcode full video with optimal settings
transcode_full_video() {
    local video_file="$1"
    local output_file="$2"
    local quality_value="$3"
    
    # -q:v: Constant quality mode (0-100, higher = higher quality/bitrate)
    ffmpeg -i "$video_file" \
        -c:v hevc_videotoolbox \
        -q:v ${quality_value} \
        -c:a copy \
        -movflags +faststart \
        -tag:v hvc1 \
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
    
    # Check if source video is already within acceptable range or below target
    SOURCE_BITRATE_BPS=$(get_source_bitrate "$VIDEO_FILE" "$VIDEO_DURATION")
    
    if [ -n "$SOURCE_BITRATE_BPS" ]; then
        SOURCE_BITRATE_MBPS=$(echo "scale=2; $(sanitize_value "$SOURCE_BITRATE_BPS") / 1000000" | bc | tr -d '\n\r' | xargs)
        
        # Check if source is within ±10% of target
        if is_within_tolerance "$SOURCE_BITRATE_BPS" "$LOWER_BOUND" "$UPPER_BOUND"; then
            info "Source video bitrate: ${SOURCE_BITRATE_MBPS} Mbps"
            info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (acceptable range: ±10%)"
            info "Source video is already within acceptable range (10% of target). No transcoding needed."
            exit 0
        fi
        
        # Check if source is already below target (already more compressed than desired)
        if (( $(echo "$(sanitize_value "$SOURCE_BITRATE_BPS") < $TARGET_BITRATE_BPS" | bc -l) )); then
            info "Source video bitrate: ${SOURCE_BITRATE_MBPS} Mbps"
            info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps"
            info "Source video is already below target bitrate. No transcoding needed."
            
            # Rename file to include actual bitrate: {base}.orig.{bitrate}.Mbps.{ext}
            local base_name="${VIDEO_FILE%.*}"
            local file_extension="${VIDEO_FILE##*.}"
            local renamed_file="${base_name}.orig.${SOURCE_BITRATE_MBPS}.Mbps.${file_extension}"
            
            # Only rename if the filename would be different
            if [ "$VIDEO_FILE" != "$renamed_file" ]; then
                mv "$VIDEO_FILE" "$renamed_file"
                info "Renamed file to: $renamed_file"
            fi
            
            exit 0
        fi
    fi
    
    # Generate temporary output filename for transcoding
    local base_name="${VIDEO_FILE%.*}"
    local file_extension="${VIDEO_FILE##*.}"
    local temp_output_file="${base_name}_temp_transcode.${file_extension}"
    
    # Calculate sample points
    calculate_sample_points "$VIDEO_DURATION"
    
    # Find optimal quality setting (using constant quality mode)
    OPTIMAL_QUALITY=$(find_optimal_quality "$VIDEO_FILE" "$TARGET_BITRATE_BPS" "$LOWER_BOUND" "$UPPER_BOUND" "$SAMPLE_START_1" "$SAMPLE_START_2" "$SAMPLE_START_3" "$SAMPLE_DURATION")
    
    info "Optimal quality setting found: ${OPTIMAL_QUALITY} (higher = higher quality/bitrate)"
    info "Starting full video transcoding with constant quality mode..."
    
    # Transcode full video to temporary file
    transcode_full_video "$VIDEO_FILE" "$temp_output_file" "$OPTIMAL_QUALITY"
    
    # Measure actual bitrate of transcoded file
    local actual_bitrate_bps=$(measure_bitrate "$temp_output_file" "$VIDEO_DURATION")
    if [ -z "$actual_bitrate_bps" ]; then
        error "Could not measure bitrate of transcoded file"
        rm -f "$temp_output_file"
        exit 1
    fi
    
    # Calculate actual bitrate in Mbps (with 2 decimal places)
    local actual_bitrate_mbps=$(echo "scale=2; $(sanitize_value "$actual_bitrate_bps") / 1000000" | bc | tr -d '\n\r' | xargs)
    
    # Generate final output filename: {base}.fmpg.{actual_bitrate}.Mbps.{ext}
    OUTPUT_FILE="${base_name}.fmpg.${actual_bitrate_mbps}.Mbps.${file_extension}"
    
    # Rename temporary file to final filename
    mv "$temp_output_file" "$OUTPUT_FILE"
    
    # Clean up any remaining sample files
    cleanup_samples "$VIDEO_FILE"
    
    info "Transcoding complete!"
    info "Output file: $OUTPUT_FILE"
    info "Actual bitrate: ${actual_bitrate_mbps} Mbps"
}

# Run main function
main

