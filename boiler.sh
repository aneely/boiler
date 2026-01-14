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

# Flag to track if script was interrupted
INTERRUPTED=0

# Global target bitrate override (Mbps) - set via command-line flag
GLOBAL_TARGET_BITRATE_MBPS=""

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

# Signal handler for interrupts (Ctrl+C)
handle_interrupt() {
    INTERRUPTED=1
    error ""
    error "Interrupted by user (Ctrl+C) - stopping all processing..."
    cleanup_on_exit
    # Force immediate exit
    exit 130  # Standard exit code for SIGINT
}

# Set up signal handlers
trap cleanup_on_exit EXIT TERM
trap handle_interrupt INT

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

# Sanitize value for bc calculations (remove newlines, carriage returns, and trim whitespace)
sanitize_value() {
    echo "$1" | tr -d '\n\r' | xargs
}

# Validate bitrate value
# Arguments: bitrate_value (Mbps as string)
# Returns: 0 if valid, 1 if invalid
validate_bitrate() {
    local bitrate="$1"
    
    # Check if empty
    if [ -z "$bitrate" ]; then
        return 1
    fi
    
    # Check if it's a valid number (allows decimals)
    if ! echo "$bitrate" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        return 1
    fi
    
    # Check if positive and within reasonable range (0.1 to 100 Mbps)
    local bitrate_clean=$(sanitize_value "$bitrate")
    if (( $(echo "$bitrate_clean <= 0" | bc -l) )) || (( $(echo "$bitrate_clean > 100" | bc -l) )); then
        return 1
    fi
    
    return 0
}

# Show usage information
show_usage() {
    cat >&2 <<EOF
Usage: $0 [OPTIONS]

Transcode video files with automatic quality optimization.

OPTIONS:
    -t, --target-bitrate RATE    Override target bitrate for all files (Mbps)
                                 Example: --target-bitrate 9.5
                                 Applies the specified bitrate to all videos
                                 regardless of resolution.

    -h, --help                   Show this help message and exit

EXAMPLES:
    # Transcode with default resolution-based bitrates
    $0

    # Transcode all files targeting 9.5 Mbps
    $0 --target-bitrate 9.5

    # Using short flag
    $0 -t 6.0

DEFAULT TARGET BITRATES (by resolution):
    2160p (4K):    11 Mbps
    1080p (Full HD): 8 Mbps
    720p (HD):      5 Mbps
    480p (SD):      2.5 Mbps

The script processes all video files in the current directory and
subdirectories (one level deep), automatically skipping files that
are already encoded.
EOF
}

# Parse command-line arguments
# Sets global variable GLOBAL_TARGET_BITRATE_MBPS if --target-bitrate or -t is provided
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -t|--target-bitrate)
                if [ $# -lt 2 ]; then
                    error "Error: --target-bitrate requires a value"
                    error "Example: --target-bitrate 9.5"
                    exit 1
                fi
                local bitrate_value="$2"
                
                if ! validate_bitrate "$bitrate_value"; then
                    error "Error: Invalid bitrate value '$bitrate_value'"
                    error "Bitrate must be a positive number between 0.1 and 100 Mbps"
                    exit 1
                fi
                
                GLOBAL_TARGET_BITRATE_MBPS=$(sanitize_value "$bitrate_value")
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "Error: Unknown option '$1'"
                error "Use --help for usage information"
                exit 1
                ;;
        esac
    done
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

# Extract original filename from an encoded filename
# Arguments: encoded_filename (e.g., "video.fmpg.10.25.Mbps.mp4")
# Returns: original filename (e.g., "video.mp4") via echo
extract_original_filename() {
    local encoded_file="$1"
    local basename=$(basename "$encoded_file")
    local dirname=$(dirname "$encoded_file")
    
    # Patterns to match: {base}.{marker}.{rest}.{ext}
    # Markers: .fmpg., .orig., .hbrk.
    local original_name=""
    
    # Try .fmpg. pattern: {base}.fmpg.{bitrate}.Mbps.{ext}
    if [[ "$basename" == *".fmpg."* ]]; then
        # Extract base name (everything before .fmpg.)
        local base_part="${basename%%.fmpg.*}"
        # Extract extension (everything after last dot)
        local ext_part="${basename##*.}"
        original_name="${base_part}.${ext_part}"
    # Try .orig. pattern: {base}.orig.{bitrate}.Mbps.{ext}
    elif [[ "$basename" == *".orig."* ]]; then
        local base_part="${basename%%.orig.*}"
        local ext_part="${basename##*.}"
        original_name="${base_part}.${ext_part}"
    # Try .hbrk. pattern: {base}.hbrk.{rest}.{ext}
    elif [[ "$basename" == *".hbrk."* ]]; then
        local base_part="${basename%%.hbrk.*}"
        local ext_part="${basename##*.}"
        original_name="${base_part}.${ext_part}"
    fi
    
    # If we found an original name and have a directory, prepend it
    if [ -n "$original_name" ] && [ "$dirname" != "." ]; then
        echo "${dirname}/${original_name}"
    elif [ -n "$original_name" ]; then
        echo "$original_name"
    else
        echo ""
    fi
}

# Check if an encoded file has its original file in the current directory
# Arguments: encoded_filename
# Returns: 0 (true) if original exists, 1 (false) if not
has_original_file() {
    local encoded_file="$1"
    local original_file=$(extract_original_filename "$encoded_file")
    
    if [ -z "$original_file" ]; then
        return 1  # Could not extract original filename
    fi
    
    # Check if original file exists
    if [ -f "$original_file" ]; then
        return 0  # Original exists
    fi
    
    return 1  # Original does not exist
}

# Check if a potential original file has an encoded version in the same directory
# Arguments: potential_original_filename
# Returns: 0 (true) if encoded version exists, 1 (false) if not
has_encoded_version() {
    local original_file="$1"
    local basename=$(basename "$original_file")
    local dirname=$(dirname "$original_file")
    
    # Normalize directory: use "." for current directory, otherwise use the directory path
    if [ "$dirname" = "." ]; then
        local search_dir="."
        local maxdepth=1
    else
        local search_dir="$dirname"
        local maxdepth=1
    fi
    
    # Extract base name and extension
    local base_part="${basename%.*}"
    local ext_part="${basename##*.}"
    
    # Check for encoded versions by looking for files that start with {base}.{marker}
    # and end with .{ext}
    local markers=("fmpg" "orig" "hbrk")
    
    for marker in "${markers[@]}"; do
        # Use find to look for files matching: {base}.{marker}.*.{ext}
        # We'll check if any file starts with the base and marker pattern
        local pattern="${base_part}.${marker}."
        local found=$(find "$search_dir" -maxdepth "$maxdepth" -type f -iname "${pattern}*.${ext_part}" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            return 0  # Found encoded version
        fi
    done
    
    return 1  # No encoded version found
}

# Check if a file should be skipped based on filename markers or original/encoded relationship
# Returns 0 (true) if file should be skipped, 1 (false) if it should be processed
# Arguments: filename
should_skip_file() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    # Check if filename contains any of the skip markers
    if [[ "$basename" == *".hbrk."* ]] || \
       [[ "$basename" == *".fmpg."* ]] || \
       [[ "$basename" == *".orig."* ]]; then
        return 0  # Should skip
    fi
    
    # Check if this file has an encoded version (skip original if encoded exists)
    if has_encoded_version "$filename"; then
        return 0  # Should skip (encoded version exists)
    fi
    
    return 1  # Should process
}

# Find all video files in current directory and subdirectories (one level deep, excluding skipped files)
# Returns all matching video files, one per line
find_all_video_files() {
    local video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv")
    local video_files=()

    for ext in "${video_extensions[@]}"; do
        while IFS= read -r found; do
            if [ -n "$found" ]; then
                # Skip files that contain markers indicating they're already processed
                if ! should_skip_file "$found"; then
                    video_files+=("$found")
                fi
            fi
        done < <(find . -maxdepth 2 -type f -iname "*.${ext}" 2>/dev/null)
    done

    # Print each file on a separate line
    for file in "${video_files[@]}"; do
        echo "$file"
    done
}

# Find all skipped video files (files with .hbrk., .fmpg., or .orig. markers)
# Returns all skipped video files, one per line (includes current directory and subdirectories one level deep)
find_skipped_video_files() {
    local video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv")
    local skipped_files=()

    for ext in "${video_extensions[@]}"; do
        while IFS= read -r found; do
            if [ -n "$found" ]; then
                # Only include files that should be skipped
                if should_skip_file "$found"; then
                    skipped_files+=("$found")
                fi
            fi
        done < <(find . -maxdepth 2 -type f -iname "*.${ext}" 2>/dev/null)
    done

    # Print each file on a separate line
    for file in "${skipped_files[@]}"; do
        echo "$file"
    done
}

# Find first video file in current directory (for backward compatibility)
find_video_file() {
    local first_file=$(find_all_video_files | head -1)
    
    if [ -z "$first_file" ]; then
        # Check if there are skipped files to mention
        local skipped_files=()
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                skipped_files+=("$line")
            fi
        done < <(find_skipped_video_files)
        
        if [ ${#skipped_files[@]} -gt 0 ]; then
            error "No video files to encode found in current directory"
            info "The following files are already encoded and were skipped:"
            for skipped_file in "${skipped_files[@]}"; do
                info "  - $(basename "$skipped_file")"
            done
        else
            error "No video file to encode found in current directory"
        fi
        exit 1
    fi

    echo "$first_file"
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

# Convert bitrate from bits per second to megabits per second
# Arguments: bitrate_bps
# Returns: bitrate in Mbps with 2 decimal places
bps_to_mbps() {
    local bitrate_bps=$(sanitize_value "$1")
    echo "scale=2; $bitrate_bps / 1000000" | bc | tr -d '\n\r' | xargs
}

# Calculate squared distance between a bitrate and target bitrate
# Used for oscillation detection to find the quality value closest to target
# Arguments: bitrate_bps, target_bitrate_bps
# Returns: squared distance
calculate_squared_distance() {
    local bitrate_bps=$(sanitize_value "$1")
    local target_bitrate_bps=$(sanitize_value "$2")
    echo "scale=4; ($bitrate_bps - $target_bitrate_bps)^2" | bc | tr -d '\n\r'
}

# Parse filename into base name and extension
# Arguments: filename
# Returns: BASE_NAME FILE_EXTENSION (via global variables)
parse_filename() {
    local filename="$1"
    BASE_NAME="${filename%.*}"
    FILE_EXTENSION="${filename##*.}"
}

# Check if file is MKV container format
# Arguments: filename
# Returns: 0 if MKV, 1 otherwise
is_mkv_file() {
    local filename="$1"
    local ext="${filename##*.}"
    # Convert to lowercase for comparison (bash 3.2 compatible)
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [ "$ext_lower" = "mkv" ]; then
        return 0
    else
        return 1
    fi
}

# Check if file format is not natively QuickLook compatible (needs remuxing to MP4)
# Arguments: filename
# Returns: 0 if needs remuxing, 1 otherwise
is_non_quicklook_format() {
    local filename="$1"
    local ext="${filename##*.}"
    # Convert to lowercase for comparison (bash 3.2 compatible)
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    
    # Formats that need remuxing: mkv, wmv, avi, webm, flv
    case "$ext_lower" in
        mkv|wmv|avi|webm|flv)
            return 0  # Needs remuxing
            ;;
        *)
            return 1  # Already QuickLook compatible (mp4, mov, m4v)
            ;;
    esac
}

# Check if video codec is compatible with MP4 container (can be copied without transcoding)
# Arguments: codec_name
# Returns: 0 if compatible, 1 if not compatible
is_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    
    # MP4-compatible codecs that can be copied directly
    case "$codec_lower" in
        h264|avc1|hevc|h265|mpeg4|mpeg4video|mpeg2video|vp8|vp9)
            return 0  # Compatible
            ;;
        wmv3|wmv1|wmv2|vc1|rv40|rv30|theora)
            return 1  # Not compatible with MP4
            ;;
        *)
            # Unknown codec - assume compatible and let FFmpeg handle it
            return 0
            ;;
    esac
}

# Get video codec name from a video file
# Arguments: file_path
# Returns: codec name (or empty string if unavailable)
get_video_codec() {
    local file_path="$1"
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r'
}

# Handle non-QuickLook format files that are at/below target bitrate
# Checks codec compatibility and either remuxes or sets up transcoding
# Arguments: video_file, source_bitrate_mbps, needs_transcode_flag_ref (name of variable to set)
# Returns: 0 if handled (remuxed or set up for transcoding), 1 if error
# Sets needs_transcode_flag_ref=1 if transcoding needed, 0 otherwise
handle_non_quicklook_at_target() {
    local video_file="$1"
    local source_bitrate_mbps="$2"
    local needs_transcode_flag_ref="$3"
    
    # Initialize the flag variable
    eval "$needs_transcode_flag_ref=0"
    
    # Parse filename to get extension
    parse_filename "$video_file"
    
    # Check if file is non-QuickLook format
    if ! is_non_quicklook_format "$video_file"; then
        return 1  # Not a non-QuickLook format
    fi
    
    local format_name=$(echo "$FILE_EXTENSION" | tr '[:upper:]' '[:lower:]')
    local format_upper=$(echo "$format_name" | tr '[:lower:]' '[:upper:]')
    
    # Get video codec
    local video_codec=$(get_video_codec "$video_file")
    
    if [ -z "$video_codec" ]; then
        error "Could not detect video codec for $video_file"
        return 1
    fi
    
    # Check codec compatibility
    if ! is_codec_mp4_compatible "$video_codec"; then
        # Codec is incompatible - set up transcoding
        warn "Video codec '$video_codec' is not compatible with MP4 container. Transcoding to HEVC at source bitrate (${source_bitrate_mbps} Mbps) for QuickLook compatibility..."
        eval "$needs_transcode_flag_ref=1"
        return 0  # Successfully set up for transcoding
    else
        # Codec is compatible - try remuxing
        info "File is ${format_upper} format. Remuxing to MP4 with QuickLook compatibility (copying streams, no transcoding)..."
        
        # Generate MP4 output filename: {base}.orig.{bitrate}.Mbps.mp4
        local output_file="${BASE_NAME}.orig.${source_bitrate_mbps}.Mbps.mp4"
        
        # Remux to MP4
        if remux_to_mp4 "$video_file" "$output_file"; then
            # Remove original file only if remux succeeded
            rm -f "$video_file"
            info "Remuxed file to: $output_file"
            return 0
        else
            error "Failed to remux ${format_upper} file. Original file preserved."
            rm -f "$output_file"  # Clean up partial output
            return 1
        fi
    fi
}

# Remux non-QuickLook compatible video file to MP4 with QuickLook compatibility
# Copies video and audio streams without transcoding
# Supports: mkv, wmv, avi, webm, flv (only if codec is MP4-compatible)
# Arguments: input_file, output_file
# Returns: 0 on success, 1 on failure
remux_to_mp4() {
    local input_file="$1"
    local output_file="$2"
    
    # Detect video codec to check compatibility and determine if we need HEVC tag
    local video_codec=$(get_video_codec "$input_file")
    
    if [ -z "$video_codec" ]; then
        error "Could not detect video codec for $input_file"
        return 1
    fi
    
    # Check if codec is compatible with MP4 container
    if ! is_codec_mp4_compatible "$video_codec"; then
        local codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')
        warn "Video codec '$video_codec' is not compatible with MP4 container (cannot be copied without transcoding). Skipping remux for $input_file"
        return 1
    fi
    
    # Build ffmpeg command: copy all streams, add QuickLook compatibility flags
    # Start with base command
    local ffmpeg_args=(-i "$input_file" -c:v copy -c:a copy -movflags +faststart)
    
    # Add HEVC tag if video codec is HEVC/H.265 for QuickLook compatibility
    # Convert to lowercase for comparison (bash 3.2 compatible)
    local codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')
    if [ "$codec_lower" = "hevc" ] || [ "$codec_lower" = "h265" ]; then
        ffmpeg_args+=(-tag:v hvc1)
    fi
    
    # Add output format and file
    ffmpeg_args+=(-f mp4 "$output_file")
    
    # Execute ffmpeg command
    ffmpeg "${ffmpeg_args[@]}" -loglevel info -stats
}

# Backward compatibility alias (for existing code that calls remux_mkv_to_mp4)
remux_mkv_to_mp4() {
    remux_to_mp4 "$@"
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
    elif [ "$resolution" -ge 720 ]; then
        TARGET_BITRATE_MBPS=5
        TARGET_BITRATE_BPS=$((TARGET_BITRATE_MBPS * 1000000))
        info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (720p)"
    elif [ "$resolution" -ge 480 ]; then
        TARGET_BITRATE_MBPS=2.5
        TARGET_BITRATE_BPS=$(printf "%.0f" "$(echo "scale=2; $TARGET_BITRATE_MBPS * 1000000" | bc | tr -d '\n\r')" | tr -d '\n\r')
        info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (480p)"
    else
        warn "Resolution ${resolution}p is below 480p, using 480p target bitrate (2.5 Mbps)"
        TARGET_BITRATE_MBPS=2.5
        TARGET_BITRATE_BPS=$(printf "%.0f" "$(echo "scale=2; $TARGET_BITRATE_MBPS * 1000000" | bc | tr -d '\n\r')" | tr -d '\n\r')
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
    # 60 is a good starting point
    local test_quality=60
    
    # Track previous iterations for oscillation detection (can detect cycles of 2-3 values)
    local prev_quality=""
    local prev_bitrate_bps=""
    local prev_prev_quality=""
    local prev_prev_bitrate_bps=""
    
    info "Starting quality adjustment process..."
    info "Using constant quality mode (-q:v), sampling from multiple points to find optimal quality setting"
    info "Using proportional adjustment algorithm (adjusts step size based on distance from target)"
    
    while true; do
        # Check if interrupted before each iteration
        if [ "$INTERRUPTED" -eq 1 ]; then
            error "Optimization interrupted, exiting"
            exit 130
        fi
        
        iteration=$((iteration + 1))
        info "Iteration $iteration: Testing with quality=${test_quality} (higher = higher quality/bitrate)"
        
        # Sample from multiple points and average the bitrates
        local total_bitrate_bps=0
        local sample_count=0
        local sample_index=0
        
        for sample_start in "$sample_start_1" "$sample_start_2" "$sample_start_3"; do
            # Check if interrupted before processing each sample
            if [ "$INTERRUPTED" -eq 1 ]; then
                error "Optimization interrupted, exiting"
                exit 130
            fi
            
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
            actual_bitrate_mbps=$(bps_to_mbps "$actual_bitrate_bps")
        else
            error "Invalid sample_count for average calculation"
            exit 1
        fi
        info "Average bitrate from $sample_count samples: ${actual_bitrate_mbps} Mbps"
        
        # Check if within acceptable range
        if is_within_tolerance "$actual_bitrate_bps" "$lower_bound" "$upper_bound"; then
            info "Bitrate is within acceptable range (5% of target)"
            break
        fi
        
        # Adjust quality setting based on actual output bitrate using proportional adjustment
        # VideoToolbox -q:v scale: higher value = higher quality = higher bitrate
        # Proportional adjustment: larger adjustments when far from target, smaller when close
        local old_quality=$test_quality
        local quality_adjustment=0
        local target_bitrate_mbps=$(bps_to_mbps "$target_bitrate_bps")
        
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
        
        # Detect oscillation: if we're about to try a quality value we've already tested recently
        # This detects cycles of 2-3 quality values (e.g., 60 ↔ 61 ↔ 62)
        local oscillation_detected=0
        local best_quality=""
        local best_bitrate_bps=""
        local best_distance=""
        
        if [ -n "$prev_quality" ] && [ "$test_quality" = "$prev_quality" ]; then
            # We're about to test the same quality as last iteration - 2-value oscillation
            oscillation_detected=1
            # Compare current and previous quality
            local current_distance=$(calculate_squared_distance "$actual_bitrate_bps" "$target_bitrate_bps")
            local prev_distance=$(calculate_squared_distance "$prev_bitrate_bps" "$target_bitrate_bps")
            
            if (( $(echo "$current_distance < $prev_distance" | bc -l) )); then
                best_quality=$old_quality
                best_bitrate_bps=$actual_bitrate_bps
            else
                best_quality=$prev_quality
                best_bitrate_bps=$prev_bitrate_bps
            fi
        elif [ -n "$prev_prev_quality" ] && [ "$test_quality" = "$prev_prev_quality" ]; then
            # We're about to test a quality from 2 iterations ago - 3-value cycle detected
            oscillation_detected=1
            # Compare all three quality values: current, prev, and prev_prev
            local current_distance=$(calculate_squared_distance "$actual_bitrate_bps" "$target_bitrate_bps")
            local prev_distance=$(calculate_squared_distance "$prev_bitrate_bps" "$target_bitrate_bps")
            local prev_prev_distance=$(calculate_squared_distance "$prev_prev_bitrate_bps" "$target_bitrate_bps")
            
            # Find the closest one
            if (( $(echo "$current_distance <= $prev_distance" | bc -l) )) && (( $(echo "$current_distance <= $prev_prev_distance" | bc -l) )); then
                best_quality=$old_quality
                best_bitrate_bps=$actual_bitrate_bps
            elif (( $(echo "$prev_distance <= $prev_prev_distance" | bc -l) )); then
                best_quality=$prev_quality
                best_bitrate_bps=$prev_bitrate_bps
            else
                best_quality=$prev_prev_quality
                best_bitrate_bps=$prev_prev_bitrate_bps
            fi
        fi
        
        if [ "$oscillation_detected" -eq 1 ]; then
            local best_bitrate_mbps=$(bps_to_mbps "$best_bitrate_bps")
            info "Oscillation detected. Using quality=${best_quality} (closest to target: ${best_bitrate_mbps} Mbps)"
            test_quality=$best_quality
            break
        fi
        
        # Store current values for next iteration's oscillation detection
        prev_prev_quality=$prev_quality
        prev_prev_bitrate_bps=$prev_bitrate_bps
        prev_quality=$old_quality
        prev_bitrate_bps=$actual_bitrate_bps
    done
    
    echo "$test_quality"
}

# Calculate adjusted quality value based on actual bitrate vs target bitrate
# Uses the same proportional adjustment algorithm as find_optimal_quality
# Arguments: current_quality, actual_bitrate_bps, target_bitrate_bps
# Returns: adjusted quality value
calculate_adjusted_quality() {
    local current_quality=$(sanitize_value "$1")
    local actual_bitrate_bps=$(sanitize_value "$2")
    local target_bitrate_bps=$(sanitize_value "$3")
    
    local min_step=1      # Minimum adjustment step (for fine-tuning when close)
    local max_step=10     # Maximum adjustment step (for large corrections when far off)
    local quality_adjustment=0
    
    if (( $(echo "$actual_bitrate_bps < $target_bitrate_bps" | bc -l) )); then
        # Actual bitrate too low, need higher quality (increase quality value)
        # Calculate ratio: how far below target are we? (0.0 = at target, 0.5 = 50% of target, etc.)
        local ratio=$(echo "scale=4; $actual_bitrate_bps / $target_bitrate_bps" | bc | tr -d '\n\r')
        # Calculate adjustment: scale from min_step to max_step based on how far off we are
        local distance_from_target=$(echo "scale=4; 1 - $ratio" | bc | tr -d '\n\r')
        # Calculate adjustment and round to nearest integer
        local adjustment_float=$(echo "scale=4; $min_step + ($max_step - $min_step) * $distance_from_target" | bc | tr -d '\n\r')
        quality_adjustment=$(printf "%.0f" "$adjustment_float" | tr -d '\n\r' | xargs)
        # Ensure it's at least min_step
        if [ "$quality_adjustment" -lt "$min_step" ]; then
            quality_adjustment=$min_step
        fi
        
        current_quality=$((current_quality + quality_adjustment))
        if [ $current_quality -gt 100 ]; then
            current_quality=100  # Maximum quality value (highest quality/bitrate)
        fi
    else
        # Actual bitrate too high, need lower quality (decrease quality value)
        # Calculate ratio: how far above target are we? (1.0 = at target, 2.0 = 200% of target, etc.)
        local ratio=$(echo "scale=4; $actual_bitrate_bps / $target_bitrate_bps" | bc | tr -d '\n\r')
        # Calculate adjustment: scale from min_step to max_step based on how far off we are
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
        
        current_quality=$((current_quality - quality_adjustment))
        if [ $current_quality -lt 0 ]; then
            current_quality=0  # Minimum quality value (lowest quality/bitrate)
        fi
    fi
    
    echo "$current_quality"
}

# Calculate quality using linear interpolation between two known points
# Arguments: quality1, bitrate1_bps, quality2, bitrate2_bps, target_bitrate_bps
# Returns: interpolated quality value
# Uses linear interpolation: quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)
calculate_interpolated_quality() {
    local quality1=$(sanitize_value "$1")
    local bitrate1_bps=$(sanitize_value "$2")
    local quality2=$(sanitize_value "$3")
    local bitrate2_bps=$(sanitize_value "$4")
    local target_bitrate_bps=$(sanitize_value "$5")
    
    # Calculate the difference in bitrates
    local bitrate_diff=$(echo "scale=4; $bitrate1_bps - $bitrate2_bps" | bc | tr -d '\n\r')
    
    # Check if bitrates are too close (would cause division by zero or unstable interpolation)
    # If bitrate difference is less than 1% of target, fall back to simple adjustment
    local min_diff=$(echo "scale=0; $target_bitrate_bps * 0.01" | bc | tr -d '\n\r')
    if (( $(echo "$bitrate_diff < $min_diff" | bc -l) )) && (( $(echo "$bitrate_diff > -$min_diff" | bc -l) )); then
        # Bitrates too close, use midpoint quality
        local interpolated_quality=$(echo "scale=4; ($quality1 + $quality2) / 2" | bc | tr -d '\n\r')
        interpolated_quality=$(printf "%.0f" "$interpolated_quality" | tr -d '\n\r' | xargs)
    else
        # Calculate interpolation: quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)
        local quality_diff=$(echo "scale=4; $quality1 - $quality2" | bc | tr -d '\n\r')
        local target_diff=$(echo "scale=4; $target_bitrate_bps - $bitrate2_bps" | bc | tr -d '\n\r')
        local ratio=$(echo "scale=4; $target_diff / $bitrate_diff" | bc | tr -d '\n\r')
        local interpolated_quality_float=$(echo "scale=4; $quality2 + $quality_diff * $ratio" | bc | tr -d '\n\r')
        interpolated_quality=$(printf "%.0f" "$interpolated_quality_float" | tr -d '\n\r' | xargs)
    fi
    
    # Clamp to valid range [0, 100]
    if [ "$interpolated_quality" -lt 0 ]; then
        interpolated_quality=0
    elif [ "$interpolated_quality" -gt 100 ]; then
        interpolated_quality=100
    fi
    
    echo "$interpolated_quality"
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

# Preprocess non-QuickLook compatible files: remux files that are within tolerance or below target
# This runs before the main file discovery to catch files that should be remuxed
# Also processes .orig. files (nondestructive remuxing for QuickLook compatibility)
# Returns: number of files remuxed
preprocess_non_quicklook_files() {
    local non_quicklook_extensions=("mkv" "wmv" "avi" "webm" "flv")
    local files_to_check=()
    local remuxed_count=0
    
    # Find all non-QuickLook format files
    # Include files with .orig. markers (nondestructive remuxing) and files without markers
    for ext in "${non_quicklook_extensions[@]}"; do
        while IFS= read -r found; do
            if [ -n "$found" ] && [ -f "$found" ]; then
                local basename=$(basename "$found")
                # Include files without markers OR files with .orig. marker (for nondestructive remuxing)
                if ! should_skip_file "$found" || [[ "$basename" == *".orig."* ]]; then
                    # Double-check: only include if it's actually a non-QuickLook format
                    if is_non_quicklook_format "$found"; then
                        files_to_check+=("$found")
                    fi
                fi
            fi
        done < <(find . -maxdepth 2 -type f -iname "*.${ext}" 2>/dev/null)
    done
    
    if [ ${#files_to_check[@]} -eq 0 ]; then
        return 0  # No files to process
    fi
    
    info "Pre-processing: Checking ${#files_to_check[@]} non-QuickLook compatible file(s) for remuxing..."
    
    # Check requirements (only check once)
    if [ -z "${REQUIREMENTS_CHECKED:-}" ]; then
        check_requirements
        export REQUIREMENTS_CHECKED=1
    fi
    
    # Process each file
    for file_path in "${files_to_check[@]}"; do
        # Check if interrupted
        if [ "$INTERRUPTED" -eq 1 ]; then
            error "Pre-processing interrupted, exiting"
            exit 130
        fi
        
        local basename=$(basename "$file_path")
        local is_orig_file=0
        
        # Check if this is an .orig. file (already marked as acceptable, just needs remuxing)
        if [[ "$basename" == *".orig."* ]]; then
            is_orig_file=1
        fi
        
        # For .orig. files, extract bitrate from filename and remux directly
        # For other files, check bitrate to determine if remuxing is needed
        if [ "$is_orig_file" -eq 1 ]; then
            # Extract bitrate from filename: {base}.orig.{bitrate}.Mbps.{ext}
            # We'll preserve the existing filename structure, just change extension to .mp4
            parse_filename "$file_path"
            
            # Extract bitrate from filename if possible (format: {base}.orig.{bitrate}.Mbps.{ext})
            local bitrate_from_filename=""
            if [[ "$basename" == *".orig."*".Mbps."* ]]; then
                # Extract bitrate: everything between .orig. and .Mbps.
                local temp="${basename#*.orig.}"
                bitrate_from_filename="${temp%%.Mbps.*}"
            fi
            
            # Generate output filename: preserve .orig.{bitrate}.Mbps. structure, change extension to .mp4
            local output_file=""
            if [ -n "$bitrate_from_filename" ]; then
                # Use bitrate from filename
                local base_part="${basename%%.orig.*}"
                local dirname=$(dirname "$file_path")
                if [ "$dirname" != "." ]; then
                    output_file="${dirname}/${base_part}.orig.${bitrate_from_filename}.Mbps.mp4"
                else
                    output_file="${base_part}.orig.${bitrate_from_filename}.Mbps.mp4"
                fi
            else
                # Fallback: get bitrate from file if not in filename
                local video_duration
                local source_bitrate_bps
                local source_bitrate_mbps
                
                if ! video_duration=$(get_video_duration "$file_path" 2>/dev/null); then
                    warn "Skipping $file_path: Could not determine duration"
                    continue
                fi
                
                source_bitrate_bps=$(get_source_bitrate "$file_path" "$video_duration")
                if [ -z "$source_bitrate_bps" ]; then
                    warn "Skipping $file_path: Could not determine bitrate"
                    continue
                fi
                source_bitrate_mbps=$(bps_to_mbps "$source_bitrate_bps")
                
                local base_part="${basename%%.orig.*}"
                local dirname=$(dirname "$file_path")
                if [ "$dirname" != "." ]; then
                    output_file="${dirname}/${base_part}.orig.${source_bitrate_mbps}.Mbps.mp4"
                else
                    output_file="${base_part}.orig.${source_bitrate_mbps}.Mbps.mp4"
                fi
            fi
            
            # Show directory context if file is in a subdirectory
            local file_dir=$(dirname "$file_path")
            if [ "$file_dir" != "." ]; then
                info "Remuxing .orig. file $file_path for QuickLook compatibility (nondestructive)"
            else
                info "Remuxing .orig. file $(basename "$file_path") for QuickLook compatibility (nondestructive)"
            fi
            
            # Remux to MP4
            if remux_to_mp4 "$file_path" "$output_file"; then
                # Remove original file only if remux succeeded
                rm -f "$file_path"
                remuxed_count=$((remuxed_count + 1))
                if [ "$file_dir" != "." ]; then
                    info "Remuxed to: $output_file"
                else
                    info "Remuxed to: $(basename "$output_file")"
                fi
            else
                error "Failed to remux $file_path. Original file preserved."
                rm -f "$output_file"  # Clean up partial output
            fi
        else
            # Regular file: check bitrate to determine if remuxing is needed
            # Get video properties
            local resolution
            local video_duration
            local source_bitrate_bps
            local source_bitrate_mbps
            local target_bitrate_mbps
            local target_bitrate_bps
            local lower_bound
            local upper_bound
            
            # Skip if we can't get resolution (file might be corrupted)
            if ! resolution=$(get_video_resolution "$file_path" 2>/dev/null); then
                warn "Skipping $file_path: Could not determine resolution"
                continue
            fi
            
            # Skip if we can't get duration
            if ! video_duration=$(get_video_duration "$file_path" 2>/dev/null); then
                warn "Skipping $file_path: Could not determine duration"
                continue
            fi
            
            # Calculate target bitrate (use global override if set, otherwise use resolution-based)
            if [ -n "$GLOBAL_TARGET_BITRATE_MBPS" ]; then
                target_bitrate_mbps=$GLOBAL_TARGET_BITRATE_MBPS
                target_bitrate_bps=$(printf "%.0f" "$(echo "scale=2; $target_bitrate_mbps * 1000000" | bc | tr -d '\n\r')" | tr -d '\n\r')
            else
                calculate_target_bitrate "$resolution"
                target_bitrate_mbps=$TARGET_BITRATE_MBPS
                target_bitrate_bps=$TARGET_BITRATE_BPS
            fi
            
            # Calculate acceptable bitrate range (within 5% of target)
            lower_bound=$(echo "$target_bitrate_bps * 0.95" | bc | tr -d '\n\r')
            upper_bound=$(echo "$target_bitrate_bps * 1.05" | bc | tr -d '\n\r')
            
            # Get source bitrate
            source_bitrate_bps=$(get_source_bitrate "$file_path" "$video_duration")
            
            if [ -z "$source_bitrate_bps" ]; then
                warn "Skipping $file_path: Could not determine bitrate"
                continue
            fi
            
            source_bitrate_mbps=$(bps_to_mbps "$source_bitrate_bps")
            
            # Check if source is within tolerance or below target
            local should_remux=0
            
            if is_within_tolerance "$source_bitrate_bps" "$lower_bound" "$upper_bound"; then
                should_remux=1
            elif (( $(echo "$(sanitize_value "$source_bitrate_bps") < $target_bitrate_bps" | bc -l) )); then
                should_remux=1
            fi
            
            if [ "$should_remux" -eq 1 ]; then
                # Parse filename to get base name
                parse_filename "$file_path"
                local output_file="${BASE_NAME}.orig.${source_bitrate_mbps}.Mbps.mp4"
                
                # Show directory context if file is in a subdirectory
                local file_dir=$(dirname "$file_path")
                local needs_transcode=0
                
                # Use helper function to handle non-QuickLook format
                if handle_non_quicklook_at_target "$file_path" "$source_bitrate_mbps" "needs_transcode"; then
                    if [ "$needs_transcode" -eq 1 ]; then
                        # Codec is incompatible - transcode instead of remuxing
                        # Transcode with source bitrate as target (preserve bitrate, improve compatibility)
                        if transcode_video "$file_path" "$source_bitrate_mbps"; then
                            # Remove original file only if transcoding succeeded
                            rm -f "$file_path"
                            remuxed_count=$((remuxed_count + 1))
                        else
                            error "Failed to transcode $file_path. Original file preserved."
                        fi
                    else
                        # Remuxing succeeded (handled by helper function)
                        remuxed_count=$((remuxed_count + 1))
                        if [ "$file_dir" != "." ]; then
                            info "Remuxed to: $output_file"
                        else
                            info "Remuxed to: $(basename "$output_file")"
                        fi
                    fi
                else
                    error "Failed to handle $file_path. Original file preserved."
                    rm -f "$output_file"  # Clean up partial output
                fi
            fi
        fi
    done
    
    if [ $remuxed_count -gt 0 ]; then
        info "Pre-processing complete: Remuxed ${remuxed_count} file(s) for QuickLook compatibility"
    fi
    
    return $remuxed_count
}

# Transcode video function
# Arguments: [video_file] [target_bitrate_override_mbps] - Optional. If video_file provided, processes that file. Otherwise finds first file in current directory.
#            If target_bitrate_override_mbps provided, uses that as target bitrate instead of resolution-based target.
transcode_video() {
    local provided_file="$1"
    local target_bitrate_override_mbps="$2"
    
    # Check requirements (only check once, not for each file)
    if [ -z "${REQUIREMENTS_CHECKED:-}" ]; then
        check_requirements
        export REQUIREMENTS_CHECKED=1
    fi
    
    # Use provided file or find video file
    if [ -n "$provided_file" ]; then
        VIDEO_FILE="$provided_file"
    else
        VIDEO_FILE=$(find_video_file)
    fi
    
    info "Found video file: $VIDEO_FILE"
    
    # Get video properties
    RESOLUTION=$(get_video_resolution "$VIDEO_FILE")
    info "Video resolution: ${RESOLUTION}p"
    
    VIDEO_DURATION=$(get_video_duration "$VIDEO_FILE")
    
    # Calculate target bitrate (use override if provided, otherwise use resolution-based target)
    if [ -n "$target_bitrate_override_mbps" ]; then
        TARGET_BITRATE_MBPS="$target_bitrate_override_mbps"
        TARGET_BITRATE_BPS=$(printf "%.0f" "$(echo "scale=2; $TARGET_BITRATE_MBPS * 1000000" | bc | tr -d '\n\r')" | tr -d '\n\r')
        info "Target bitrate (override): ${TARGET_BITRATE_MBPS} Mbps"
    else
        calculate_target_bitrate "$RESOLUTION"
    fi
    
    # Calculate acceptable bitrate range (within 5% of target)
    LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.95" | bc | tr -d '\n\r')
    UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.05" | bc | tr -d '\n\r')
    
    # Check if source video is already within acceptable range or below target
    SOURCE_BITRATE_BPS=$(get_source_bitrate "$VIDEO_FILE" "$VIDEO_DURATION")
    
    # Flag to track if we need to transcode due to codec incompatibility
    local needs_transcode_for_compatibility=0
    
    if [ -n "$SOURCE_BITRATE_BPS" ]; then
        SOURCE_BITRATE_MBPS=$(bps_to_mbps "$SOURCE_BITRATE_BPS")
        
        # Check if source is within ±5% of target
        if is_within_tolerance "$SOURCE_BITRATE_BPS" "$LOWER_BOUND" "$UPPER_BOUND"; then
            info "Source video bitrate: ${SOURCE_BITRATE_MBPS} Mbps"
            info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (acceptable range: ±5%)"
            info "Source video is already within acceptable range (5% of target). No transcoding needed."
            
            parse_filename "$VIDEO_FILE"
            
            # Check if file needs remuxing to MP4 for QuickLook compatibility
            if is_non_quicklook_format "$VIDEO_FILE"; then
                # Use helper function to handle non-QuickLook format
                if handle_non_quicklook_at_target "$VIDEO_FILE" "$SOURCE_BITRATE_MBPS" "needs_transcode_for_compatibility"; then
                    # If remuxing succeeded, helper already handled it and we should return early
                    if [ "$needs_transcode_for_compatibility" -eq 0 ]; then
                        return 0
                    fi
                    # If codec incompatible, set up transcoding with source bitrate
                    TARGET_BITRATE_MBPS="$SOURCE_BITRATE_MBPS"
                    TARGET_BITRATE_BPS="$SOURCE_BITRATE_BPS"
                    LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.95" | bc | tr -d '\n\r')
                    UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.05" | bc | tr -d '\n\r')
                    # Continue to transcoding section
                else
                    # Error handling non-QuickLook format
                    return 1
                fi
            else
                # Rename file to include actual bitrate: {base}.orig.{bitrate}.Mbps.{ext}
                local renamed_file="${BASE_NAME}.orig.${SOURCE_BITRATE_MBPS}.Mbps.${FILE_EXTENSION}"
                
                # Only rename if the filename would be different
                if [ "$VIDEO_FILE" != "$renamed_file" ]; then
                    mv "$VIDEO_FILE" "$renamed_file"
                    info "Renamed file to: $renamed_file"
                fi
                return 0
            fi
            
            # Only return early if we don't need to transcode for compatibility
            if [ "$needs_transcode_for_compatibility" -eq 0 ]; then
                return 0
            fi
            # Otherwise, fall through to transcoding section below
        fi
        
        # Check if source is already below target (already more compressed than desired)
        if (( $(echo "$(sanitize_value "$SOURCE_BITRATE_BPS") < $TARGET_BITRATE_BPS" | bc -l) )); then
            info "Source video bitrate: ${SOURCE_BITRATE_MBPS} Mbps"
            info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps"
            info "Source video is already below target bitrate. No transcoding needed."
            
            parse_filename "$VIDEO_FILE"
            
            # Check if file needs remuxing to MP4 for QuickLook compatibility
            if is_non_quicklook_format "$VIDEO_FILE"; then
                # Use helper function to handle non-QuickLook format
                if handle_non_quicklook_at_target "$VIDEO_FILE" "$SOURCE_BITRATE_MBPS" "needs_transcode_for_compatibility"; then
                    # If remuxing succeeded, helper already handled it and we should return early
                    if [ "$needs_transcode_for_compatibility" -eq 0 ]; then
                        return 0
                    fi
                    # If codec incompatible, set up transcoding with source bitrate
                    TARGET_BITRATE_MBPS="$SOURCE_BITRATE_MBPS"
                    TARGET_BITRATE_BPS="$SOURCE_BITRATE_BPS"
                    LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.95" | bc | tr -d '\n\r')
                    UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.05" | bc | tr -d '\n\r')
                    # Continue to transcoding section
                else
                    # Error handling non-QuickLook format
                    return 1
                fi
            else
                # Rename file to include actual bitrate: {base}.orig.{bitrate}.Mbps.{ext}
                local renamed_file="${BASE_NAME}.orig.${SOURCE_BITRATE_MBPS}.Mbps.${FILE_EXTENSION}"
                
                # Only rename if the filename would be different
                if [ "$VIDEO_FILE" != "$renamed_file" ]; then
                    mv "$VIDEO_FILE" "$renamed_file"
                    info "Renamed file to: $renamed_file"
                fi
                return 0
            fi
            
            # Only return early if we don't need to transcode for compatibility
            if [ "$needs_transcode_for_compatibility" -eq 0 ]; then
                return 0
            fi
            # Otherwise, fall through to transcoding section below
        fi
    fi
    
    # Generate temporary output filename for transcoding
    parse_filename "$VIDEO_FILE"
    local temp_output_file="${BASE_NAME}_temp_transcode.${FILE_EXTENSION}"
    
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
        return 1
    fi
    
    # Calculate actual bitrate in Mbps (with 2 decimal places)
    local actual_bitrate_mbps=$(bps_to_mbps "$actual_bitrate_bps")
    
    # Check if final bitrate is within tolerance - if not, do one more pass with adjusted quality
    if ! is_within_tolerance "$actual_bitrate_bps" "$LOWER_BOUND" "$UPPER_BOUND"; then
        warn "First pass bitrate (${actual_bitrate_mbps} Mbps) is outside tolerance range. Performing second pass with adjusted quality..."
        
        # Store first pass data for potential interpolation
        local first_pass_quality=$OPTIMAL_QUALITY
        local first_pass_bitrate_bps=$actual_bitrate_bps
        
        # Calculate adjusted quality value based on actual vs target bitrate
        local adjusted_quality=$(calculate_adjusted_quality "$OPTIMAL_QUALITY" "$actual_bitrate_bps" "$TARGET_BITRATE_BPS")
        local target_bitrate_mbps=$(bps_to_mbps "$TARGET_BITRATE_BPS")
        info "Adjusting quality from ${OPTIMAL_QUALITY} to ${adjusted_quality} based on actual bitrate (${actual_bitrate_mbps} Mbps vs ${target_bitrate_mbps} Mbps target)"
        
        # Remove first pass temporary file
        rm -f "$temp_output_file"
        
        # Transcode again with adjusted quality
        transcode_full_video "$VIDEO_FILE" "$temp_output_file" "$adjusted_quality"
        
        # Measure actual bitrate of second pass
        local second_pass_bitrate_bps=$(measure_bitrate "$temp_output_file" "$VIDEO_DURATION")
        if [ -z "$second_pass_bitrate_bps" ]; then
            error "Could not measure bitrate of second pass transcoded file"
            rm -f "$temp_output_file"
            return 1
        fi
        
        # Recalculate actual bitrate in Mbps
        local second_pass_bitrate_mbps=$(bps_to_mbps "$second_pass_bitrate_bps")
        
        # Check if second pass is within tolerance
        if is_within_tolerance "$second_pass_bitrate_bps" "$LOWER_BOUND" "$UPPER_BOUND"; then
            info "Second pass bitrate (${second_pass_bitrate_mbps} Mbps) is within tolerance range"
            actual_bitrate_bps=$second_pass_bitrate_bps
            actual_bitrate_mbps=$second_pass_bitrate_mbps
        else
            # Second pass still out of range - use linear interpolation between the two known points
            warn "Second pass bitrate (${second_pass_bitrate_mbps} Mbps) is still outside tolerance range. Performing third pass with interpolated quality..."
            
            # Use linear interpolation: we have (quality1, bitrate1) and (quality2, bitrate2)
            # Interpolate to find quality that should give us target bitrate
            local interpolated_quality=$(calculate_interpolated_quality "$first_pass_quality" "$first_pass_bitrate_bps" "$adjusted_quality" "$second_pass_bitrate_bps" "$TARGET_BITRATE_BPS")
            local first_pass_bitrate_mbps=$(bps_to_mbps "$first_pass_bitrate_bps")
            info "Interpolating quality from first pass (${first_pass_quality} → ${first_pass_bitrate_mbps} Mbps) and second pass (${adjusted_quality} → ${second_pass_bitrate_mbps} Mbps) to ${interpolated_quality} for target (${target_bitrate_mbps} Mbps)"
            
            # Remove second pass temporary file
            rm -f "$temp_output_file"
            
            # Transcode with interpolated quality
            transcode_full_video "$VIDEO_FILE" "$temp_output_file" "$interpolated_quality"
            
            # Measure actual bitrate of third pass
            actual_bitrate_bps=$(measure_bitrate "$temp_output_file" "$VIDEO_DURATION")
            if [ -z "$actual_bitrate_bps" ]; then
                error "Could not measure bitrate of third pass transcoded file"
                rm -f "$temp_output_file"
                return 1
            fi
            
            # Recalculate actual bitrate in Mbps
            actual_bitrate_mbps=$(bps_to_mbps "$actual_bitrate_bps")
            
            # Check if third pass is within tolerance (informational only - we'll use this result regardless)
            if is_within_tolerance "$actual_bitrate_bps" "$LOWER_BOUND" "$UPPER_BOUND"; then
                info "Third pass bitrate (${actual_bitrate_mbps} Mbps) is within tolerance range"
            else
                warn "Third pass bitrate (${actual_bitrate_mbps} Mbps) is still outside tolerance range, but using this result"
            fi
        fi
    fi
    
    # Generate final output filename
    # Use .orig. pattern if transcoding for compatibility (source bitrate override), otherwise use .fmpg.
    # Always use .mp4 extension when transcoding (HEVC in MP4 container)
    if [ "$needs_transcode_for_compatibility" -eq 1 ]; then
        OUTPUT_FILE="${BASE_NAME}.orig.${actual_bitrate_mbps}.Mbps.mp4"
    else
        OUTPUT_FILE="${BASE_NAME}.fmpg.${actual_bitrate_mbps}.Mbps.mp4"
    fi
    
    # Rename temporary file to final filename
    mv "$temp_output_file" "$OUTPUT_FILE"
    
    # Clean up any remaining sample files
    cleanup_samples "$VIDEO_FILE"
    
    info "Transcoding complete!"
    info "Output file: $OUTPUT_FILE"
    info "Actual bitrate: ${actual_bitrate_mbps} Mbps"
    
    return 0
}

# Main function - processes all video files in current directory
main() {
    # Parse command-line arguments
    parse_arguments "$@"
    
    # Preprocess non-QuickLook compatible files first (remux files within tolerance or below target)
    preprocess_non_quicklook_files
    
    # Get all video files in current directory (bash 3.2 compatible - no mapfile)
    local video_files=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            video_files+=("$line")
        fi
    done < <(find_all_video_files)
    
    if [ ${#video_files[@]} -eq 0 ]; then
        # Check if there are skipped files to mention
        local skipped_files=()
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                skipped_files+=("$line")
            fi
        done < <(find_skipped_video_files)
        
        if [ ${#skipped_files[@]} -gt 0 ]; then
            error "No video files to encode found in current directory"
            info "The following files are already encoded and were skipped:"
            for skipped_file in "${skipped_files[@]}"; do
                info "  - $(basename "$skipped_file")"
            done
        else
            error "No video files to encode found in current directory"
        fi
        exit 1
    fi
    
    local total_files=${#video_files[@]}
    local current_file=0
    
    info "Found ${total_files} video file(s) to process"
    
    # Process each video file
    for video_file in "${video_files[@]}"; do
        # Check if interrupted before processing next file
        if [ "$INTERRUPTED" -eq 1 ]; then
            error "Processing interrupted, exiting"
            exit 130
        fi
        
        current_file=$((current_file + 1))
        info ""
        # Show directory context if file is in a subdirectory
        local file_dir=$(dirname "$video_file")
        if [ "$file_dir" != "." ]; then
            info "Processing file ${current_file}/${total_files}: $video_file"
        else
            info "Processing file ${current_file}/${total_files}: $(basename "$video_file")"
        fi
        info "=========================================="
        
        # Process this file (transcode_video handles its own errors)
        # Check for interrupt after each file
        # Pass global target bitrate override if set
        if [ -n "$GLOBAL_TARGET_BITRATE_MBPS" ]; then
            transcode_video "$video_file" "$GLOBAL_TARGET_BITRATE_MBPS" || {
                # If interrupted, exit immediately
                if [ "$INTERRUPTED" -eq 1 ]; then
                    error "Processing interrupted, exiting"
                    exit 130
                fi
                warn "Failed to process: $video_file"
                # Continue with next file instead of exiting
            }
        else
            transcode_video "$video_file" || {
                # If interrupted, exit immediately
                if [ "$INTERRUPTED" -eq 1 ]; then
                    error "Processing interrupted, exiting"
                    exit 130
                fi
                warn "Failed to process: $video_file"
                # Continue with next file instead of exiting
            }
        fi
        
        # Check again after processing (in case interrupt happened during transcoding)
        if [ "$INTERRUPTED" -eq 1 ]; then
            error "Processing interrupted, exiting"
            exit 130
        fi
    done
    
    info ""
    info "Batch processing complete! Processed ${total_files} file(s)"
}

# Run main function (unless in test mode)
if [ -z "${BOILER_TEST_MODE:-}" ]; then
    main "$@"
fi

