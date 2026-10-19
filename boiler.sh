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

# Global max depth for directory traversal (default: 2 = current directory + one subdirectory level)
# Set to 0 for unlimited depth (full recursive search)
# Only set default if not already set (allows environment variable override for testing)
GLOBAL_MAX_DEPTH="${GLOBAL_MAX_DEPTH:-2}"

# Auto-crop (opt-in): detect and remove baked-in black bars while transcoding.
# AUTO_CROP=1 via --auto-crop; CROP_DETECT_ONLY=1 via --crop-detect-only (report only, no encoding).
# CROP_PARAMS holds the active crop for the file being processed (W:H:X:Y), or empty for none.
# It is reset at the start of every transcode_video() call and read by transcode_sample()
# and transcode_full_video() so samples and every full-encode pass use the same crop.
AUTO_CROP=0
CROP_DETECT_ONLY=0
CROP_PARAMS=""
# Tuning knobs (env-overridable for testing and threshold tuning)
CROP_SAMPLE_WINDOWS="${CROP_SAMPLE_WINDOWS:-12}"    # Detection windows spread across the video
CROP_SAMPLE_SECONDS="${CROP_SAMPLE_SECONDS:-3}"     # Length of each detection window
CROP_MIN_REMOVED_PCT="${CROP_MIN_REMOVED_PCT:-3}"   # Ignore crops that remove less than this % of the frame
CROP_LIMIT="${CROP_LIMIT:-24}"                      # cropdetect black threshold on an 8-bit (0-255) scale; scaled to the source bit depth
CROP_OUTLIER_PX="${CROP_OUTLIER_PX:-16}"            # Per-edge spread that marks a window as an outlier
CROP_DEBUG="${CROP_DEBUG:-0}"                       # 1 = print each detection window's start, raw box and the union

# Encoded output extension: transcoded/remuxed output is always .mp4 (HEVC in MP4 container).
# Used by has_encoded_version() and final output naming so "already transcoded" detection works for non-.mp4 originals.
ENCODED_OUTPUT_EXTENSION="mp4"

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

# Normalize pipeline output: strip newlines/carriage returns and trim leading/trailing whitespace.
# Reads stdin, writes normalized value to stdout. Used by sanitize_value and bc/printf pipelines.
# Uses sed instead of xargs so Bats tests run in restricted environments where xargs can fail with sysconf(_SC_ARG_MAX) failed.
normalize_output() {
    tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Sanitize value for bc calculations (remove newlines, carriage returns, and trim whitespace)
sanitize_value() {
    echo "$1" | normalize_output
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

# Validate depth value
# Arguments: depth_value (integer as string)
# Returns: 0 if valid, 1 if invalid
validate_depth() {
    local depth="$1"
    
    # Check if empty
    if [ -z "$depth" ]; then
        return 1
    fi
    
    # Check if it's a non-negative integer (0 for unlimited, or positive integer)
    if ! echo "$depth" | grep -qE '^[0-9]+$'; then
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

    -L, --max-depth DEPTH        Maximum directory depth to traverse
                                 Example: --max-depth 3
                                 Default: 2 (current directory + one subdirectory level)
                                 Use 0 for unlimited depth (full recursive search)

    --auto-crop                  Detect and remove baked-in black bars (letterbox/
                                 pillarbox) while transcoding. Opt-in. A detected
                                 crop forces a re-encode, even for files that would
                                 otherwise be skipped as already at target bitrate.
                                 The target bitrate is not changed by cropping.

    --crop-detect-only           Report the crop detected for each file and exit.
                                 Does not transcode, remux, or rename anything.

    -h, --help                   Show this help message and exit

EXAMPLES:
    # Transcode with default resolution-based bitrates (2 levels deep)
    $0

    # Transcode all files targeting 9.5 Mbps
    $0 --target-bitrate 9.5

    # Using short flag
    $0 -t 6.0

    # Process only current directory (no subdirectories)
    $0 -L 1

    # Process three levels deep
    $0 -L 3

    # Process all subdirectories recursively (unlimited depth)
    $0 -L 0

    # Combine options
    $0 --target-bitrate 9.5 -L 3

    # Preview black bar detection without changing any files
    $0 --crop-detect-only

    # Transcode and crop black bars
    $0 --auto-crop

DEFAULT TARGET BITRATES (by resolution):
    2160p (4K):    11 Mbps
    1080p (Full HD): 8 Mbps
    720p (HD):      5 Mbps
    480p (SD):      2.5 Mbps

The script processes all video files in the current directory and
subdirectories (default: one level deep), automatically skipping files that
are already encoded.
EOF
}

# Parse command-line arguments
# Sets global variable GLOBAL_TARGET_BITRATE_MBPS if --target-bitrate or -t is provided
# Sets global variable GLOBAL_MAX_DEPTH if -L or --max-depth is provided
# Sets AUTO_CROP if --auto-crop is provided; --crop-detect-only sets AUTO_CROP and CROP_DETECT_ONLY
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
            -L|--max-depth)
                if [ $# -lt 2 ]; then
                    error "Error: --max-depth requires a value"
                    error "Example: --max-depth 3"
                    error "Use 0 for unlimited depth (full recursive search)"
                    exit 1
                fi
                local depth_value="$2"
                
                if ! validate_depth "$depth_value"; then
                    error "Error: Invalid depth value '$depth_value'"
                    error "Depth must be a non-negative integer (0 for unlimited, or positive integer)"
                    exit 1
                fi
                
                GLOBAL_MAX_DEPTH=$(sanitize_value "$depth_value")
                shift 2
                ;;
            --auto-crop)
                AUTO_CROP=1
                shift
                ;;
            --crop-detect-only)
                AUTO_CROP=1
                CROP_DETECT_ONLY=1
                shift
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
    
    # Extract base name (encoded output is always ENCODED_OUTPUT_EXTENSION, not the original's extension)
    local base_part="${basename%.*}"
    
    # Check for encoded versions by looking for files that start with {base}.{marker}
    # and end with .{ENCODED_OUTPUT_EXTENSION} (transcoded/remuxed output is always .mp4)
    local markers=("fmpg" "orig" "hbrk")

    # find -iname treats the pattern as a glob, so escape glob characters in the filename
    # (otherwise names like "Movie [2024].mp4" never match their own encoded copy and get
    # re-encoded on every run)
    local escaped_base
    escaped_base=$(printf '%s' "$base_part" | sed 's/[][*?\\]/\\&/g')

    for marker in "${markers[@]}"; do
        local pattern="${escaped_base}.${marker}."
        local found=$(find "$search_dir" -maxdepth "$maxdepth" -type f -iname "${pattern}*.${ENCODED_OUTPUT_EXTENSION}" 2>/dev/null | head -1)
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

# Find all video files in current directory and subdirectories (excluding skipped files)
# Returns all matching video files, one per line
# Uses GLOBAL_MAX_DEPTH for directory depth (0 = unlimited, default: 2)
find_all_video_files() {
    local video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv" "mpg" "mpeg" "ts")
    local video_files=()
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"

    for ext in "${video_extensions[@]}"; do
        # Use -maxdepth only if depth is not 0 (unlimited)
        if [ "$max_depth" -eq 0 ]; then
            while IFS= read -r found; do
                if [ -n "$found" ]; then
                    # Skip files that contain markers indicating they're already processed
                    if ! should_skip_file "$found"; then
                        video_files+=("$found")
                    fi
                fi
            done < <(find . -type f -iname "*.${ext}" 2>/dev/null)
        else
            while IFS= read -r found; do
                if [ -n "$found" ]; then
                    # Skip files that contain markers indicating they're already processed
                    if ! should_skip_file "$found"; then
                        video_files+=("$found")
                    fi
                fi
            done < <(find . -maxdepth "${max_depth}" -type f -iname "*.${ext}" 2>/dev/null)
        fi
    done

    # Print each file on a separate line in sorted order (predictable processing order)
    printf '%s\n' "${video_files[@]}" | sort
}

# Find all skipped video files (files with .hbrk., .fmpg., or .orig. markers)
# Returns all skipped video files, one per line
# Uses GLOBAL_MAX_DEPTH for directory depth (0 = unlimited, default: 2)
find_skipped_video_files() {
    local video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv" "mpg" "mpeg" "ts")
    local skipped_files=()
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"

    for ext in "${video_extensions[@]}"; do
        # Use -maxdepth only if depth is not 0 (unlimited)
        if [ "$max_depth" -eq 0 ]; then
            while IFS= read -r found; do
                if [ -n "$found" ]; then
                    # Only include files that should be skipped
                    if should_skip_file "$found"; then
                        skipped_files+=("$found")
                    fi
                fi
            done < <(find . -type f -iname "*.${ext}" 2>/dev/null)
        else
            while IFS= read -r found; do
                if [ -n "$found" ]; then
                    # Only include files that should be skipped
                    if should_skip_file "$found"; then
                        skipped_files+=("$found")
                    fi
                fi
            done < <(find . -maxdepth "${max_depth}" -type f -iname "*.${ext}" 2>/dev/null)
        fi
    done

    # Print each file on a separate line in sorted order (predictable order for display)
    printf '%s\n' "${skipped_files[@]}" | sort
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

# Get video width and height using ffprobe
# Returns: "WIDTH HEIGHT" (space separated), or empty string if unavailable
# Uses key=value output: the CSV writer appends a stray separator ("3840x2160x") for streams
# that carry side data (e.g. HDR metadata), which broke the bc arithmetic downstream.
get_video_dimensions() {
    local video_file="$1"
    local out w h
    out=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of default=noprint_wrappers=1 "$video_file" 2>/dev/null)
    w=$(echo "$out" | sed -n 's/^width=\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1)
    h=$(echo "$out" | sed -n 's/^height=\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1)
    if [ -n "$w" ] && [ -n "$h" ]; then
        echo "$w $h"
    fi
}

# Get the rotation tag of the first video stream (display matrix or legacy rotate tag)
# Returns: rotation in degrees, or 0 when there is none
get_video_rotation() {
    local video_file="$1"
    local line
    while IFS= read -r line; do
        line=$(sanitize_value "$line")
        if [ -n "$line" ] && ! [[ "$line" =~ ^-?0(\.0*)?$ ]]; then
            echo "$line"
            return 0
        fi
    done < <(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation:stream_tags=rotate -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null)
    echo "0"
}

# Extract the final crop=W:H:X:Y value from ffmpeg cropdetect output
#
# With cropdetect's reset=0 the reported box is cumulative across frames, so the last
# line is the bounding box of everything seen in the window.
#
# Arguments: ffmpeg_output (text)
# Only well-formed lines are accepted (four non-empty numeric fields ending the line), so a
# truncated or garbled line can never reach the bc/arithmetic code downstream.
#
# Arguments: ffmpeg_output (text)
# Returns: "W:H:X:Y" on stdout, or empty string if no valid crop line was found
parse_cropdetect_output() {
    echo "$1" | tr -d '\r' \
        | grep -E '(^|[[:space:]])crop=[0-9]+:[0-9]+:[0-9]+:[0-9]+[[:space:]]*$' \
        | tail -1 | sed -E 's/^.*crop=([0-9]+:[0-9]+:[0-9]+:[0-9]+)[[:space:]]*$/\1/' || true
}

# Succeeds when the argument is a well-formed W:H:X:Y box of non-negative integers
is_crop_box() {
    [[ "$1" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]
}

# Succeeds when the argument is a positive integer
is_positive_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

# Succeeds when the argument is a non-negative decimal number (e.g. a duration in seconds)
is_decimal() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# Combine several W:H:X:Y boxes into their union (most conservative crop)
# Any box with real content near an edge pulls the union back toward the full frame.
#
# Arguments: one or more "W:H:X:Y" boxes
# Returns: "W:H:X:Y" union on stdout, or empty string when no boxes are given
combine_crop_boxes() {
    local min_x="" min_y="" max_x="" max_y=""
    local box w h x y x2 y2
    for box in "$@"; do
        IFS=: read -r w h x y <<< "$box"
        x2=$((x + w))
        y2=$((y + h))
        if [ -z "$min_x" ]; then
            min_x=$x; min_y=$y; max_x=$x2; max_y=$y2
            continue
        fi
        [ "$x" -lt "$min_x" ] && min_x=$x
        [ "$y" -lt "$min_y" ] && min_y=$y
        [ "$x2" -gt "$max_x" ] && max_x=$x2
        [ "$y2" -gt "$max_y" ] && max_y=$y2
    done
    if [ -z "$min_x" ]; then
        echo ""
    else
        echo "$((max_x - min_x)):$((max_y - min_y)):${min_x}:${min_y}"
    fi
}

# Percentage of the frame removed by a crop
# Arguments: crop (W:H:X:Y), frame_width, frame_height
# Returns: percentage with one decimal place (e.g. 25.9)
crop_removed_pct() {
    local crop="$1"
    local frame_w=$(sanitize_value "$2")
    local frame_h=$(sanitize_value "$3")
    local w h x y
    if ! is_crop_box "$crop" || ! is_positive_int "$frame_w" || ! is_positive_int "$frame_h"; then
        warn "Cannot compute removed area: crop='$crop' frame='${frame_w}x${frame_h}'"
        echo "0.0"
        return 0
    fi
    IFS=: read -r w h x y <<< "$crop"
    local pct
    pct=$(echo "scale=6; (1 - ($w * $h) / ($frame_w * $frame_h)) * 100" | bc -l | normalize_output)
    printf "%.1f" "${pct:-0}"
}

# Check that a crop is safe to apply
# Rejects odd values (chroma-unsafe), tiny crops, crops under 50% of either dimension
# (almost certainly a bad detection) and crops that fall outside the frame.
#
# Arguments: crop (W:H:X:Y), frame_width, frame_height
# Returns: 0 if safe, 1 otherwise (reason is printed as a warning)
validate_crop_params() {
    local crop="$1"
    local frame_w="$2"
    local frame_h="$3"
    local w h x y
    IFS=: read -r w h x y <<< "$crop"

    if [ -z "$w" ] || [ -z "$h" ] || [ -z "$x" ] || [ -z "$y" ]; then
        warn "Ignoring malformed crop '$crop'"
        return 1
    fi
    if [ $((w % 2)) -ne 0 ] || [ $((h % 2)) -ne 0 ] || [ $((x % 2)) -ne 0 ] || [ $((y % 2)) -ne 0 ]; then
        warn "Ignoring crop $crop: values must be even"
        return 1
    fi
    if [ "$w" -lt 16 ] || [ "$h" -lt 16 ]; then
        warn "Ignoring crop $crop: result would be smaller than 16 pixels"
        return 1
    fi
    if [ $((w * 2)) -lt "$frame_w" ] || [ $((h * 2)) -lt "$frame_h" ]; then
        warn "Ignoring crop $crop: would remove more than half of the ${frame_w}x${frame_h} frame (likely a bad detection)"
        return 1
    fi
    if [ $((x + w)) -gt "$frame_w" ] || [ $((y + h)) -gt "$frame_h" ]; then
        warn "Ignoring crop $crop: falls outside the ${frame_w}x${frame_h} frame"
        return 1
    fi
    return 0
}

# Detect black bars by running cropdetect over windows spread across the video
#
# Windows are evenly spaced between 5% and 95% of the duration (skips fades and logos),
# each CROP_SAMPLE_SECONDS long. The result is the union of all windows' boxes, so a dark
# scene or a scene with a different aspect ratio can only make the crop smaller.
#
# Arguments: video_file, duration_seconds, frame_width, frame_height
# Returns (stdout): "W:H:X:Y", or empty string when no crop should be applied
# Diagnostics go to stderr via info/warn so only the crop is captured by $()
detect_black_bars() {
    local video_file="$1"
    local duration=$(sanitize_value "$2")
    local frame_w="$3"
    local frame_h="$4"

    local windows="$CROP_SAMPLE_WINDOWS"
    local window_secs="$CROP_SAMPLE_SECONDS"

    # Everything below feeds bc; refuse non-numeric input up front instead of letting bc fail
    if ! is_decimal "$duration"; then
        warn "Unusable duration '$duration' for crop detection; not cropping"
        echo ""
        return 0
    fi
    if ! is_positive_int "$frame_w" || ! is_positive_int "$frame_h"; then
        warn "Unusable frame size '${frame_w}x${frame_h}' for crop detection; not cropping"
        echo ""
        return 0
    fi
    if ! is_decimal "$CROP_LIMIT"; then
        warn "Invalid CROP_LIMIT='$CROP_LIMIT'; not cropping"
        echo ""
        return 0
    fi
    if ! is_positive_int "$windows" || ! is_decimal "$window_secs"; then
        warn "Invalid CROP_SAMPLE_WINDOWS='$windows' or CROP_SAMPLE_SECONDS='$window_secs'; not cropping"
        echo ""
        return 0
    fi

    # Short video: scan all of it in one window
    local whole_video=0
    if (( $(echo "$duration < $windows * $window_secs" | bc -l) )); then
        windows=1
        window_secs="$duration"
        whole_video=1
    fi

    # cropdetect compares an integer limit against raw samples at the source's native bit depth,
    # so 24 means "black" for 8-bit video but is below 10-bit black (64) and finds no bars at all.
    # A fraction of full scale is normalised per pixel format, so pass CROP_LIMIT/255.
    local limit_frac
    limit_frac=$(printf "%.6f" "$(echo "scale=8; $CROP_LIMIT / 255" | bc -l | normalize_output)")

    local boxes=()
    local i start output box
    for ((i = 0; i < windows; i++)); do
        if [ "$whole_video" -eq 1 ]; then
            start=0
        elif [ "$windows" -eq 1 ]; then
            start=$(echo "scale=2; $duration * 0.5" | bc | normalize_output)
        else
            start=$(echo "scale=2; $duration * (0.05 + 0.90 * $i / ($windows - 1))" | bc | normalize_output)
        fi
        # Keep the window inside the file
        if (( $(echo "$start + $window_secs > $duration" | bc -l) )); then
            start=$(echo "scale=2; v = $duration - $window_secs; if (v < 0) 0 else v" | bc | normalize_output)
        fi

        output=$(ffmpeg -hide_banner -nostdin -ss "$start" -i "$video_file" -t "$window_secs" \
            -map 0:v:0 -an -sn -dn \
            -vf "cropdetect=limit=${limit_frac}:round=2:reset=0" -f null - 2>&1) || true
        box=$(parse_cropdetect_output "$output")
        [ "$CROP_DEBUG" = "1" ] && info "[crop-debug] window $((i + 1))/$windows start=${start}s box=${box:-<none>}"
        [ -n "$box" ] && boxes+=("$box")
    done

    if [ "${#boxes[@]}" -eq 0 ]; then
        warn "Crop detection produced no results; not cropping"
        echo ""
        return 0
    fi

    local union
    union=$(combine_crop_boxes "${boxes[@]}")
    [ "$CROP_DEBUG" = "1" ] && info "[crop-debug] union=${union} from ${#boxes[@]} of ${windows} windows"

    # Warn when several windows disagree with the union: dark-heavy or variable-aspect content
    local ux uy uw uh x y w h outliers=0
    IFS=: read -r uw uh ux uy <<< "$union"
    for box in "${boxes[@]}"; do
        IFS=: read -r w h x y <<< "$box"
        local d_left=$((x - ux))
        local d_top=$((y - uy))
        local d_right=$(( (ux + uw) - (x + w) ))
        local d_bottom=$(( (uy + uh) - (y + h) ))
        if [ "$d_left" -gt "$CROP_OUTLIER_PX" ] || [ "$d_top" -gt "$CROP_OUTLIER_PX" ] || \
           [ "$d_right" -gt "$CROP_OUTLIER_PX" ] || [ "$d_bottom" -gt "$CROP_OUTLIER_PX" ]; then
            outliers=$((outliers + 1))
        fi
    done
    if [ $((outliers * 4)) -gt "${#boxes[@]}" ]; then
        warn "Crop windows disagree (${outliers} of ${#boxes[@]} differ from the combined crop); video may be dark-heavy or have a variable aspect ratio. Using the most conservative crop."
    fi

    local removed_pct
    removed_pct=$(crop_removed_pct "$union" "$frame_w" "$frame_h")
    if (( $(echo "$removed_pct < $CROP_MIN_REMOVED_PCT" | bc -l) )); then
        info "No significant black bars detected (${removed_pct}% of frame; minimum ${CROP_MIN_REMOVED_PCT}%)"
        echo ""
        return 0
    fi

    if ! validate_crop_params "$union" "$frame_w" "$frame_h"; then
        echo ""
        return 0
    fi

    echo "$union"
}

# Detect black bars for a file and set CROP_PARAMS (empty when no crop applies)
# Runs in the caller's shell so the global is visible; never fails the caller.
#
# Arguments: video_file, duration_seconds
detect_crop_for_file() {
    local video_file="$1"
    local duration="$2"
    CROP_PARAMS=""

    local rotation
    rotation=$(get_video_rotation "$video_file")
    if [ "$rotation" != "0" ]; then
        warn "Video has rotation metadata (${rotation}°); skipping crop detection"
        return 0
    fi

    local dims frame_w frame_h
    dims=$(get_video_dimensions "$video_file")
    read -r frame_w frame_h <<< "$dims"
    if [ -z "$frame_w" ] || [ -z "$frame_h" ]; then
        warn "Could not determine video dimensions; skipping crop detection"
        return 0
    fi

    # Mirror detect_black_bars(): a video shorter than windows x seconds is scanned whole
    if is_decimal "$duration" && is_positive_int "$CROP_SAMPLE_WINDOWS" && is_decimal "$CROP_SAMPLE_SECONDS" \
        && (( $(echo "$duration < $CROP_SAMPLE_WINDOWS * $CROP_SAMPLE_SECONDS" | bc -l) )); then
        info "Detecting black bars (scanning the whole video)..."
    else
        info "Detecting black bars (${CROP_SAMPLE_WINDOWS} windows)..."
    fi
    local crop
    crop=$(detect_black_bars "$video_file" "$duration" "$frame_w" "$frame_h") || crop=""
    if [ -n "$crop" ]; then
        local w h x y
        IFS=: read -r w h x y <<< "$crop"
        CROP_PARAMS="$crop"
        info "Crop detected: ${frame_w}x${frame_h} -> ${w}x${h} (crop=${crop}), removes $(crop_removed_pct "$crop" "$frame_w" "$frame_h")% of frame"
    fi
    return 0
}

# Verify an encoded file has exactly the frame size the crop should produce
# Arguments: output_file, crop (W:H:X:Y)
# Returns: 0 if dimensions match, 1 otherwise
verify_crop_output() {
    local output_file="$1"
    local crop="$2"
    local w h x y
    IFS=: read -r w h x y <<< "$crop"
    local dims out_w out_h
    dims=$(get_video_dimensions "$output_file")
    read -r out_w out_h <<< "$dims"
    if [ "$out_w" != "$w" ] || [ "$out_h" != "$h" ]; then
        error "Cropped output is ${out_w:-unknown}x${out_h:-unknown}, expected ${w}x${h}"
        return 1
    fi
    return 0
}

# Report detected crop for every video file without encoding or modifying anything
# (--crop-detect-only). Uses normal file discovery, so already-processed files are skipped.
run_crop_detect_only() {
    local video_files=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && video_files+=("$line")
    done < <(find_all_video_files)

    if [ ${#video_files[@]} -eq 0 ]; then
        error "No video files found in current directory"
        exit 1
    fi

    check_requirements

    local video_file duration
    for video_file in "${video_files[@]}"; do
        if [ "$INTERRUPTED" -eq 1 ]; then
            error "Interrupted, exiting"
            exit 130
        fi
        info "Checking: $video_file"
        if ! duration=$(get_video_duration "$video_file" 2>/dev/null); then
            warn "Skipping $video_file: Could not determine duration"
            continue
        fi
        detect_crop_for_file "$video_file" "$duration"
    done
}

# Convert bitrate from bits per second to megabits per second
# Arguments: bitrate_bps
# Returns: bitrate in Mbps with 2 decimal places
bps_to_mbps() {
    local bitrate_bps=$(sanitize_value "$1")
    echo "scale=2; $bitrate_bps / 1000000" | bc | normalize_output
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
    
    # Formats that need remuxing: mkv, wmv, avi, webm, flv, mpg, mpeg, ts
    case "$ext_lower" in
        mkv|wmv|avi|webm|flv|mpg|mpeg|ts)
            return 0  # Needs remuxing
            ;;
        *)
            return 1  # Already QuickLook compatible (mp4, mov, m4v)
            ;;
    esac
}

# Detect subtitle streams in a video file.
# Outputs one "display_idx|codec|language|global_idx" tuple per line.
# display_idx is 0-based within subtitle streams; global_idx is the stream index from ffprobe.
# Language is empty when the tag is absent or N/A.
# Arguments: input_file
detect_subtitle_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    local display_idx=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local global_idx codec lang
        global_idx=$(echo "$line" | cut -d',' -f1)
        codec=$(echo "$line" | cut -d',' -f2)
        lang=$(echo "$line" | cut -d',' -f3)
        [ "$lang" = "N/A" ] && lang=""
        echo "${display_idx}|${codec}|${lang}|${global_idx}"
        display_idx=$((display_idx + 1))
    done <<< "$csv"
}

# Classify a subtitle codec as convertible to mov_text (text-based) or not (image-based/unknown).
# Text-based codecs (subrip, ass, ssa, webvtt, mov_text, text) can be converted.
# Image-based codecs (hdmv_pgs_subtitle, dvd_subtitle, dvbsub, pgssub) cannot.
# Unknown codecs are treated as not convertible.
# Arguments: codec_name
# Returns: 0 if convertible, 1 if not
is_subtitle_convertible() {
    local codec="$1"
    local codec_lower
    codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    case "$codec_lower" in
        subrip|srt|ass|ssa|webvtt|mov_text|text)
            return 0
            ;;
        *)
            return 1
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

# Get audio codec name from a video file
# Arguments: file_path
# Returns: codec name (or empty string if unavailable)
get_audio_codec() {
    local file_path="$1"
    ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r'
}

# Check if audio codec is compatible with MP4 container (can be copied without transcoding)
# Arguments: codec_name
# Returns: 0 if compatible, 1 if not compatible
is_audio_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')

    # Audio codecs known to be incompatible with MP4 container
    case "$codec_lower" in
        wmav1|wmav2|wmalossless|wmapro|vorbis|adpcm_ms)
            return 1  # Not compatible with MP4
            ;;
        *)
            # Unknown or known-compatible codec (aac, ac3, eac3, mp3, mp2, alac, flac, opus, pcm_*)
            return 0
            ;;
    esac
}

# Determine audio codec argument for ffmpeg based on source audio compatibility
# Returns "copy" if audio can be copied into MP4, "aac" if it must be re-encoded
# Arguments: file_path
# Returns: "copy" or "aac" (printed to stdout)
get_audio_codec_arg() {
    local file_path="$1"
    local audio_codec
    audio_codec=$(get_audio_codec "$file_path")

    # If no audio codec detected, default to copy (no audio or detection failed)
    if [ -z "$audio_codec" ]; then
        echo "copy"
        return
    fi

    if ! is_audio_codec_mp4_compatible "$audio_codec"; then
        warn "Audio codec '$audio_codec' is not compatible with MP4 container. Re-encoding audio to AAC."
        echo "aac"
    else
        echo "copy"
    fi
}

# Count audio streams in a video file (for explicit -map so all tracks are copied)
# Arguments: file_path
# Returns: number of audio streams (0 if none or on error)
count_audio_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        echo "0"
        return 0
    fi
    local n=0
    for _ in $(echo "$csv" | tr ',' ' '); do n=$((n + 1)); done
    echo "$n"
}

# Handle non-QuickLook format files that are at/below target bitrate
# Handle non-QuickLook format files at or below target bitrate
#
# Checks codec compatibility for non-QuickLook files (MKV, WMV, AVI, WEBM, FLV) and:
#   - If codec is MP4-compatible: remuxes to MP4 (copy streams, no transcoding)
#   - If codec is incompatible: sets up transcoding flag for compatibility transcode
#
# Arguments:
#   $1 - Video file path
#   $2 - Source bitrate in Mbps
#   $3 - Name of variable to set as flag (pass by reference pattern)
#
# Side Effects:
#   Sets variable named by $3:
#     - 0 if remuxed (no transcoding needed)
#     - 1 if transcoding needed (incompatible codec)
#
# Returns:
#   0 if handled successfully, 1 if error
#
# Supported codecs for remuxing: h264, hevc, mpeg4, vp9 (in MP4)
# Incompatible codecs requiring transcoding: WMV3, etc.
#
# Used by: preprocess_non_quicklook_files, transcode_video (within tolerance case)
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
        
        # Generate MP4 output filename: {base}.orig.{bitrate}.Mbps.mp4 (same directory as source)
        local dirname=$(dirname "$video_file")
        local output_file
        if [ "$dirname" != "." ]; then
            # Use basename of BASE_NAME so we don't duplicate path (e.g. subdir/video.mkv -> subdir/video.orig.X.Mbps.mp4)
            local base_only="${BASE_NAME##*/}"
            output_file="${dirname}/${base_only}.orig.${source_bitrate_mbps}.Mbps.mp4"
        else
            output_file="${BASE_NAME}.orig.${source_bitrate_mbps}.Mbps.mp4"
        fi
        
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

# Build ffmpeg subtitle map args for convertible subtitle streams only, stored in global _SUB_MAP_ARGS.
# Silently skips image-based streams (PGS, DVD, dvbsub).
# Arguments: input_file
# Returns: 0 if at least one convertible stream was mapped, 1 if source had subtitles but none convertible
# Side effect: sets global _SUB_MAP_ARGS array (empty on return 1 or no subtitles)
append_subtitle_map_args() {
    local input_file="$1"
    _SUB_MAP_ARGS=()

    local sub_data
    sub_data=$(detect_subtitle_streams "$input_file")
    [ -z "$sub_data" ] && return 0

    local has_convertible=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local s_codec s_global_idx
        s_codec=$(echo "$line" | cut -d'|' -f2)
        s_global_idx=$(echo "$line" | cut -d'|' -f4)
        if is_subtitle_convertible "$s_codec"; then
            _SUB_MAP_ARGS+=(-map "0:${s_global_idx}")
            has_convertible=1
        fi
    done <<< "$sub_data"

    if [ "$has_convertible" -eq 1 ]; then
        _SUB_MAP_ARGS+=(-c:s mov_text)
        return 0
    else
        return 1
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
    
    # Build ffmpeg command: explicit stream mapping (first video + all audio) then copy, add QuickLook compatibility flags
    # Without -map, FFmpeg default stream selection picks only one audio track; mapping all preserves multi-track audio
    local num_audio
    num_audio=$(count_audio_streams "$input_file")
    local audio_codec_arg
    audio_codec_arg=$(get_audio_codec_arg "$input_file")
    local ffmpeg_args=(-i "$input_file" -map 0:v:0)
    [ "$num_audio" -gt 0 ] && ffmpeg_args+=(-map 0:a)
    if ! append_subtitle_map_args "$input_file"; then
        SUBTITLE_DROP_FILES+=("$output_file")
    fi
    [ "${#_SUB_MAP_ARGS[@]}" -gt 0 ] && ffmpeg_args+=("${_SUB_MAP_ARGS[@]}")
    ffmpeg_args+=(-c:v copy -c:a "$audio_codec_arg" -movflags +faststart)

    # Add HEVC tag if video codec is HEVC/H.265 for QuickLook compatibility
    # Convert to lowercase for comparison (bash 3.2 compatible)
    local codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')
    if [ "$codec_lower" = "hevc" ] || [ "$codec_lower" = "h265" ]; then
        ffmpeg_args+=(-tag:v hvc1)
    fi
    
    # Add output format and file
    ffmpeg_args+=(-f mp4 "$output_file")
    
    # Execute ffmpeg command
    local ffmpeg_exit=0
    ffmpeg "${ffmpeg_args[@]}" -loglevel error -stats || ffmpeg_exit=$?

    if [ "$ffmpeg_exit" -ne 0 ]; then
        error "FFmpeg remux failed (exit code $ffmpeg_exit) for $input_file"
        return 1
    fi

    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        error "FFmpeg remux produced no output for $input_file"
        return 1
    fi
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

    # Try stream-level bitrate first
    local bitrate_bps
    bitrate_bps=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r')

    # If stream-level is unusable (< 0.1 Mbps), try container-level bitrate.
    # WMV/ASF containers store bitrate at container level; ffprobe returns 0 or 1 bps
    # at the stream level for these files.
    if ! (( $(echo "$(sanitize_value "${bitrate_bps:-0}") >= 100000" | bc -l 2>/dev/null || echo 0) )); then
        bitrate_bps=$(ffprobe -v error -show_entries format=bit_rate \
            -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r')
    fi

    # If still unusable, fall back to file size / duration
    if ! (( $(echo "$(sanitize_value "${bitrate_bps:-0}") >= 100000" | bc -l 2>/dev/null || echo 0) )); then
        local file_size_bytes
        file_size_bytes=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null | tr -d '\n\r')
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

# Calculate target bitrate based on video resolution
#
# Arguments:
#   $1 - Video resolution height in pixels
#
# Side Effects:
#   Sets global variables:
#     - TARGET_BITRATE_MBPS: Target bitrate in Mbps
#     - TARGET_BITRATE_BPS: Target bitrate in bits per second
#
# Resolution tiers and targets:
#   2160p (4K): ≥2160px height → 11 Mbps
#   1080p (Full HD): ≥1080px height → 8 Mbps
#   720p (HD): ≥720px height → 5 Mbps
#   480p (SD): ≥480px height → 2.5 Mbps
#   Below 480p: Falls back to 480p settings (2.5 Mbps)
#
# Note: Uses height-based detection. See docs/TECHNICAL.md for
# discussion on aspect ratio handling considerations.
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

# Calculate sample points for multi-point bitrate estimation
#
# Determines how many 60-second samples can fit in the video and positions them
# at representative points (beginning, middle, end) for accurate bitrate estimation.
#
# Arguments:
#   $1 - Video duration in seconds
#
# Side Effects:
#   Sets global variables:
#     - SAMPLE_START_1: Start time (seconds) for first sample, or 0 if <60s
#     - SAMPLE_START_2: Start time for second sample, or empty if not used
#     - SAMPLE_START_3: Start time for third sample, or empty if not used
#     - SAMPLE_COUNT: Number of samples (1, 2, or 3)
#     - SAMPLE_DURATION: Duration of each sample in seconds
#
# Sampling strategy by video duration:
#   < 60s: 1 sample (entire video)
#   60-119s: 1 sample at beginning
#   120-179s: 2 samples (beginning and end)
#   ≥ 180s: 3 samples at ~10%, ~50%, ~90% positions
#
# Rationale: Longer samples provide more accurate bitrate measurements by averaging
# out variation. 60 seconds balances accuracy with iteration time. See docs/TECHNICAL.md
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
#
# Creates a short sample from the video using constant quality mode for bitrate estimation.
# Uses input seeking (-ss before -i) for faster performance, especially for later samples.
#
# Arguments:
#   $1 - Video file path
#   $2 - Sample start time in seconds
#   $3 - Sample duration in seconds
#   $4 - Quality value (0-100) for constant quality mode
#   $5 - Output file path for the sample
#
# Encoding settings:
#   - Video: HEVC via VideoToolbox (-c:v hevc_videotoolbox)
#   - Quality: Constant quality mode (-q:v, 0-100 scale)
#   - Audio: Copy if compatible with MP4, otherwise re-encode to AAC
#   - Container: MP4 with faststart for QuickLook (-movflags +faststart)
#
# Note: Uses input seeking (-ss before -i) which is faster than output seeking
# but means interrupting the script may leave FFmpeg processes running
#
# See docs/TECHNICAL.md for discussion on QuickLook compatibility
transcode_sample() {
    local video_file="$1"
    local sample_start="$2"
    local sample_duration="$3"
    local quality_value="$4"
    local output_file="$5"
    
    # Explicit stream mapping: first video stream + all audio streams (avoids default selection picking only one audio track)
    local num_audio
    num_audio=$(count_audio_streams "$video_file")
    local audio_codec_arg
    audio_codec_arg=$(get_audio_codec_arg "$video_file")
    local map_args=(-map 0:v:0)
    [ "$num_audio" -gt 0 ] && map_args+=(-map 0:a)

    # Black bar crop (empty unless --auto-crop detected one for this file)
    local vf_args=()
    if [ -n "${CROP_PARAMS:-}" ]; then
        vf_args=(-vf "crop=${CROP_PARAMS}")
    fi

    # Input seeking: -ss before -i makes seeking much faster, especially for later samples
    # -q:v: Constant quality mode (0-100, higher = higher quality/bitrate)
    local ffmpeg_exit=0
    ffmpeg -y -ss "$sample_start" \
        -i "$video_file" \
        "${map_args[@]}" \
        -t $sample_duration \
        "${vf_args[@]}" \
        -c:v hevc_videotoolbox \
        -q:v ${quality_value} \
        -c:a "$audio_codec_arg" \
        -movflags +faststart \
        -f mp4 \
        "$output_file" \
        -loglevel error -stats || ffmpeg_exit=$?

    if [ "$ffmpeg_exit" -ne 0 ]; then
        error "FFmpeg sample transcoding failed (exit code $ffmpeg_exit) for $video_file"
        return 1
    fi

    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        error "FFmpeg sample transcoding produced no output for $video_file"
        return 1
    fi
}

# Measure bitrate from a sample file
measure_sample_bitrate() {
    measure_bitrate "$1" "$2"
}

# Find optimal quality setting through iterative sampling
#
# Main optimization loop that iteratively finds the optimal quality setting
# by transcoding samples from multiple points and adjusting quality to hit target bitrate.
# Uses constant quality mode (-q:v) with VideoToolbox.
#
# Arguments:
#   $1 - Video file path
#   $2 - Target bitrate in bits per second
#   $3 - Lower bound for quality value (unused, reserved for future constraints)
#   $4 - Upper bound for quality value (unused, reserved for future constraints)
#   $5 - Sample 1 start time (seconds)
#   $6 - Sample 2 start time (seconds, may be empty)
#   $7 - Sample 3 start time (seconds, may be empty)
#   $8 - Sample duration in seconds
#
# Returns:
#   OPTIMAL_QUALITY: Quality value (0-100) that produces bitrate closest to target
#
# Algorithm:
#   1. Start with quality=60 (VideoToolbox -q:v scale: higher=higher quality/bitrate)
#   2. Transcode samples from multiple points
#   3. Calculate average bitrate across all samples
#   4. Use proportional adjustment (step size 1-10 based on distance from target)
#   5. Repeat until bitrate within ±5% tolerance or oscillation detected
#   6. Return best quality value from history if oscillation occurs
#
# See docs/TECHNICAL.md for detailed algorithm documentation
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
    local max_iterations=50  # Safety cap to prevent infinite loops
    local iteration=0
    # Start with a reasonable quality value
    # VideoToolbox -q:v scale: higher value = higher quality = higher bitrate
    # 60 is a good starting point
    local test_quality=60
    
    # Full history of tried (quality, bitrate_bps) for repeat detection and best-from-history
    # Format: space-separated "quality:bitrate_bps" (bash 3.2 compatible)
    local tried_history=""
    
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
                total_bitrate_bps=$(echo "$total_bitrate_bps + $sample_bitrate_bps" | bc | normalize_output)
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
            actual_bitrate_bps=$(echo "scale=0; $total_bitrate_bps / $sample_count" | bc | normalize_output)
            actual_bitrate_mbps=$(bps_to_mbps "$actual_bitrate_bps")
        else
            error "Invalid sample_count for average calculation"
            exit 1
        fi
        info "Average bitrate from $sample_count samples: ${actual_bitrate_mbps} Mbps"
        
        # Record this (quality, bitrate) in history for repeat detection and best-from-history
        # Use test_quality (the quality we just tested) rather than old_quality (which isn't set yet)
        if [ -z "$tried_history" ]; then
            tried_history="${test_quality}:${actual_bitrate_bps}"
        else
            tried_history="$tried_history ${test_quality}:${actual_bitrate_bps}"
        fi
        
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
            quality_adjustment=$(printf "%.0f" "$adjustment_float" | normalize_output)
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
            quality_adjustment=$(printf "%.0f" "$adjustment_float" | normalize_output)
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
        
        # Max iterations safeguard: prevent infinite loops
        local loop_exit_reason=""
        if [ "$iteration" -ge "$max_iterations" ]; then
            loop_exit_reason="max iterations ($max_iterations)"
        fi
        
        # Detect repeat: if we're about to try a quality we've already tried, we're in a loop
        # (covers 2-value oscillation, 3-value cycles, and longer or irregular cycles)
        if [ -z "$loop_exit_reason" ] && [ -n "$tried_history" ]; then
            local already_tried=0
            for entry in $tried_history; do
                [ -z "$entry" ] && continue
                local hist_quality="${entry%%:*}"
                if [ "$hist_quality" = "$test_quality" ]; then
                    already_tried=1
                    break
                fi
            done
            if [ "$already_tried" -eq 1 ]; then
                loop_exit_reason="quality ${test_quality} already tried (loop detected)"
            fi
        fi
        
        if [ -n "$loop_exit_reason" ]; then
            # Pick best (quality, bitrate) from full history by distance to target
            local best_quality=""
            local best_bitrate_bps=""
            local best_distance=""
            for entry in $tried_history; do
                [ -z "$entry" ] && continue
                local hist_quality="${entry%%:*}"
                local hist_bitrate="${entry#*:}"
                local dist=$(calculate_squared_distance "$hist_bitrate" "$target_bitrate_bps")
                local dist_lt_best
                dist_lt_best=$(echo "$dist < $best_distance" | bc -l 2>/dev/null | normalize_output)
                if [ -z "$best_distance" ] || [ "${dist_lt_best:-0}" = "1" ]; then
                    best_quality=$hist_quality
                    best_bitrate_bps=$hist_bitrate
                    best_distance=$dist
                fi
            done
            if [ -n "$best_quality" ]; then
                local best_bitrate_mbps=$(bps_to_mbps "$best_bitrate_bps")
                info "Stopping: $loop_exit_reason. Using quality=${best_quality} (closest to target: ${best_bitrate_mbps} Mbps)"
                test_quality=$best_quality
            fi
            break
        fi
    done
    
    echo "$test_quality"
}

# Calculate adjusted quality value based on actual bitrate vs target bitrate
#
# Implements proportional adjustment algorithm for multi-pass transcoding.
# Uses the same adjustment logic as find_optimal_quality for consistency.
#
# Arguments:
#   $1 - Current quality value (0-100)
#   $2 - Actual bitrate in bits per second
#   $3 - Target bitrate in bits per second
#
# Returns:
#   Adjusted quality value (echoed to stdout)
#
# Algorithm:
#   If actual < target: ratio = actual/target, distance = 1 - ratio
#                       adjustment = 1 + (10 - 1) * distance, rounded
#                       new_quality = current + adjustment
#   If actual > target: ratio = actual/target, distance = min(ratio - 1, 1.0)
#                       adjustment = 1 + (10 - 1) * distance, rounded  
#                       new_quality = current - adjustment
#
# Bounds: Quality clamped to [0, 100]
#
# Used for: Second pass transcoding when first pass is outside tolerance
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
        quality_adjustment=$(printf "%.0f" "$adjustment_float" | normalize_output)
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
        quality_adjustment=$(printf "%.0f" "$adjustment_float" | normalize_output)
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

# Calculate quality using linear interpolation between two known data points
#
# Addresses overcorrection issues in third pass transcoding where the proportional
# adjustment algorithm overcorrects due to non-linear quality-bitrate relationship.
#
# Arguments:
#   $1 - Quality value from first pass (quality1)
#   $2 - Bitrate from first pass in bps (bitrate1)
#   $3 - Quality value from second pass (quality2)
#   $4 - Bitrate from second pass in bps (bitrate2)
#   $5 - Target bitrate in bps
#
# Returns:
#   Interpolated quality value (echoed to stdout)
#
# Formula:
#   quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)
#
# Edge case handling:
#   If bitrates are within 1% of each other (unstable interpolation),
#   falls back to simple midpoint: (quality1 + quality2) / 2
#
# Bounds: Quality clamped to [0, 100]
#
# Used for: Third pass transcoding when second pass is still outside tolerance
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
        interpolated_quality=$(printf "%.0f" "$interpolated_quality" | normalize_output)
    else
        # Calculate interpolation: quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)
        local quality_diff=$(echo "scale=4; $quality1 - $quality2" | bc | tr -d '\n\r')
        local target_diff=$(echo "scale=4; $target_bitrate_bps - $bitrate2_bps" | bc | tr -d '\n\r')
        local ratio=$(echo "scale=4; $target_diff / $bitrate_diff" | bc | tr -d '\n\r')
        local interpolated_quality_float=$(echo "scale=4; $quality2 + $quality_diff * $ratio" | bc | tr -d '\n\r')
        interpolated_quality=$(printf "%.0f" "$interpolated_quality_float" | normalize_output)
    fi
    
    # Clamp to valid range [0, 100]
    if [ "$interpolated_quality" -lt 0 ]; then
        interpolated_quality=0
    elif [ "$interpolated_quality" -gt 100 ]; then
        interpolated_quality=100
    fi
    
    echo "$interpolated_quality"
}

# Transcode the complete video with optimal quality setting
#
# Performs full video transcoding using the quality value determined by the
# optimization algorithm. This is the final transcoding step after sample-based
# optimization converges.
#
# Arguments:
#   $1 - Input video file path
#   $2 - Output video file path
#   $3 - Quality value (0-100) determined by find_optimal_quality()
#
# Encoding settings:
#   - Video: HEVC via VideoToolbox (-c:v hevc_videotoolbox)
#   - Quality: Constant quality mode (-q:v, 0-100 scale)
#   - Audio: Copy if compatible with MP4, otherwise re-encode to AAC
#   - Container: MP4 with faststart and HEVC tagging
#     * -movflags +faststart: Metadata at beginning for QuickLook
#     * -tag:v hvc1: Proper HEVC codec tag for macOS compatibility
#
# Note: Uses -loglevel info -hide_banner -stats to show metadata and one updating progress line
#
# Used by: transcode_video (all three passes)
transcode_full_video() {
    local video_file="$1"
    local output_file="$2"
    local quality_value="$3"
    
    # Explicit stream mapping: first video stream + all audio streams (avoids default selection picking only one audio track)
    local num_audio
    num_audio=$(count_audio_streams "$video_file")
    local audio_codec_arg
    audio_codec_arg=$(get_audio_codec_arg "$video_file")
    local map_args=(-map 0:v:0)
    [ "$num_audio" -gt 0 ] && map_args+=(-map 0:a)
    if ! append_subtitle_map_args "$video_file"; then
        SUBTITLE_HAS_DROP_PENDING=1
    fi
    [ "${#_SUB_MAP_ARGS[@]}" -gt 0 ] && map_args+=("${_SUB_MAP_ARGS[@]}")

    # Black bar crop (empty unless --auto-crop detected one for this file)
    local vf_args=()
    if [ -n "${CROP_PARAMS:-}" ]; then
        vf_args=(-vf "crop=${CROP_PARAMS}")
    fi

    # -q:v: Constant quality mode (0-100, higher = higher quality/bitrate)
    local ffmpeg_exit=0
    ffmpeg -i "$video_file" \
        "${map_args[@]}" \
        "${vf_args[@]}" \
        -c:v hevc_videotoolbox \
        -q:v ${quality_value} \
        -c:a "$audio_codec_arg" \
        -movflags +faststart \
        -tag:v hvc1 \
        -f mp4 \
        "$output_file" \
        -loglevel info -hide_banner -stats || ffmpeg_exit=$?

    if [ "$ffmpeg_exit" -ne 0 ]; then
        error "FFmpeg transcoding failed (exit code $ffmpeg_exit) for $video_file"
        return 1
    fi

    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        error "FFmpeg transcoding produced no output for $video_file"
        return 1
    fi
}

# Clean up sample files
cleanup_samples() {
    local video_file="$1"
    rm -f "${video_file%.*}_sample"*.mp4
}

# Preprocessing pass for non-QuickLook compatible files
#
# Runs before main file discovery to handle MKV, WMV, AVI, WEBM, FLV files that are
# already within tolerance or below target bitrate. Remuxes them to MP4 for QuickLook
# compatibility without transcoding (when codec compatible) or transcodes if codec
# is incompatible (e.g., WMV3).
#
# Also handles .orig. marked files (nondestructive remuxing for QuickLook compatibility).
#
# Side Effects:
#   - Remuxes eligible files to MP4 format
#   - Removes original files after successful remuxing
#   - Sets up transcoding for incompatible codecs at source bitrate
#
# Returns:
#   Number of files remuxed (integer)
#
# Processing logic:
#   1. Find all non-QuickLook format files (including .orig. marked files)
#   2. For each file, check source bitrate
#   3. If within tolerance or below target:
#      - Check codec compatibility
#      - If compatible: remux to MP4 (copy streams)
#      - If incompatible: transcode at source bitrate for QuickLook compatibility
#   4. Remove original file after successful processing
#
# Supported formats: mkv, wmv, avi, webm, flv, mpg, mpeg, ts
preprocess_non_quicklook_files() {
    local non_quicklook_extensions=("mkv" "wmv" "avi" "webm" "flv" "mpg" "mpeg" "ts")
    local files_to_check=()
    local remuxed_count=0
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"
    
    # Find all non-QuickLook format files
    # Include files with .orig. markers (nondestructive remuxing) and files without markers
    for ext in "${non_quicklook_extensions[@]}"; do
        # Use -maxdepth only if depth is not 0 (unlimited)
        if [ "$max_depth" -eq 0 ]; then
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
            done < <(find . -type f -iname "*.${ext}" 2>/dev/null)
        else
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
            done < <(find . -maxdepth "${max_depth}" -type f -iname "*.${ext}" 2>/dev/null)
        fi
    done
    
    if [ ${#files_to_check[@]} -eq 0 ]; then
        return 0  # No files to process
    fi
    
    # Sort for predictable processing order
    local sorted_files=()
    while IFS= read -r line; do
        sorted_files+=("$line")
    done < <(printf '%s\n' "${files_to_check[@]}" | sort)
    files_to_check=("${sorted_files[@]}")
    
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
            
            # With --auto-crop, a file that needs cropping must be re-encoded, not remuxed.
            # Leave it untouched so the main pass transcodes it from the original.
            if [ "$should_remux" -eq 1 ] && [ "${AUTO_CROP:-0}" -eq 1 ]; then
                detect_crop_for_file "$file_path" "$video_duration"
                if [ -n "$CROP_PARAMS" ]; then
                    info "Crop detected; skipping remux so $file_path is re-encoded with the crop"
                    CROP_PARAMS=""
                    continue
                fi
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
                        # Codec is incompatible - transcode instead of remuxing.
                        # Pass source bitrate as target only when it's a meaningful non-zero
                        # value — a zero source bitrate (ffprobe returning 0 for stream
                        # metadata) would set TARGET_BITRATE_BPS=0 and cause divide-by-zero.
                        local transcode_target_override=""
                        if (( $(echo "$(sanitize_value "${source_bitrate_bps:-0}") >= 100000" | bc -l 2>/dev/null || echo 0) )); then
                            transcode_target_override="$source_bitrate_mbps"
                        fi
                        if transcode_video "$file_path" "$transcode_target_override"; then
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

# Main transcoding orchestration function
#
# Orchestrates the complete transcoding workflow for a single video file:
#   1. Analyzes video properties (resolution, duration, bitrate)
#   2. Determines target bitrate (resolution-based or override)
#   3. Short-circuits if source already optimized
#   4. Handles non-QuickLook format compatibility
#   5. Finds optimal quality via iterative sampling
#   6. Performs full video transcoding
#   7. Performs second pass if needed
#   8. Performs third pass with interpolation if needed
#
# Arguments:
#   $1 - Video file path (optional, if omitted finds first file in current directory)
#   $2 - Target bitrate override in Mbps (optional, uses resolution-based target if omitted)
#
# Returns:
#   0 on success, 1 on failure
#
# Side Effects:
#   - Creates transcoded output file with naming: {base}.fmpg.{bitrate}.Mbps.{ext}
#   - Creates .orig. renamed file if source already optimized
#   - Removes original file after successful transcoding
#   - Sets VIDEO_FILE global for cleanup handlers
#
# Multi-pass strategy:
#   Pass 1: Sample-based optimization → Full transcode
#   Pass 2: If outside tolerance, proportional adjustment → Re-transcode
#   Pass 3: If still outside tolerance, linear interpolation → Final transcode
#
# See docs/TECHNICAL.md for detailed algorithm documentation
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

    # Detect black bars (opt-in). Reset first so a crop never leaks from the previous file.
    # Runs before the target/short-circuit logic because an applied crop forces a re-encode.
    CROP_PARAMS=""
    if [ "${AUTO_CROP:-0}" -eq 1 ]; then
        detect_crop_for_file "$VIDEO_FILE" "$VIDEO_DURATION"
    fi
    
    # Calculate target bitrate (use override if provided, otherwise use resolution-based target)
    # The tier always comes from the original (pre-crop) height and cropping never changes the target.
    if [ -n "$target_bitrate_override_mbps" ]; then
        TARGET_BITRATE_MBPS="$target_bitrate_override_mbps"
        TARGET_BITRATE_BPS=$(printf "%.0f" "$(echo "scale=2; $TARGET_BITRATE_MBPS * 1000000" | bc | tr -d '\n\r')" | tr -d '\n\r')
        info "Target bitrate (override): ${TARGET_BITRATE_MBPS} Mbps"
    else
        calculate_target_bitrate "$RESOLUTION"
    fi
    
    # Measure source bitrate (needed before the bounds when a crop is active)
    SOURCE_BITRATE_BPS=$(get_source_bitrate "$VIDEO_FILE" "$VIDEO_DURATION")

    # A crop forces a re-encode. If the source is below the default tier target, re-encoding
    # at the full tier target would inflate it, so use the source bitrate as the target (same
    # precedent as incompatible-codec re-encodes). An explicit --target-bitrate is never changed.
    if [ -n "$CROP_PARAMS" ] && [ -z "$target_bitrate_override_mbps" ] && [ -n "$SOURCE_BITRATE_BPS" ] && \
       (( $(echo "$(sanitize_value "$SOURCE_BITRATE_BPS") >= 100000" | bc -l 2>/dev/null || echo 0) )) && \
       (( $(echo "$(sanitize_value "$SOURCE_BITRATE_BPS") < $TARGET_BITRATE_BPS" | bc -l) )); then
        TARGET_BITRATE_MBPS=$(bps_to_mbps "$SOURCE_BITRATE_BPS")
        TARGET_BITRATE_BPS="$SOURCE_BITRATE_BPS"
        info "Source bitrate is below the tier target; using source bitrate (${TARGET_BITRATE_MBPS} Mbps) as target for the cropped re-encode"
    fi
    
    # Calculate acceptable bitrate range (within 5% of target)
    LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.95" | bc | tr -d '\n\r')
    UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.05" | bc | tr -d '\n\r')
    
    # Check if source video is already within acceptable range or below target
    # (skipped entirely when a crop is active: the file must be re-encoded to apply it)
    
    # Flag to track if we need to transcode due to codec incompatibility
    local needs_transcode_for_compatibility=0
    
    if [ -n "$SOURCE_BITRATE_BPS" ]; then
        SOURCE_BITRATE_MBPS=$(bps_to_mbps "$SOURCE_BITRATE_BPS")
        
        # Check if source is within ±5% of target
        if [ -z "$CROP_PARAMS" ] && is_within_tolerance "$SOURCE_BITRATE_BPS" "$LOWER_BOUND" "$UPPER_BOUND"; then
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
                    # If codec incompatible, set up transcoding with source bitrate.
                    # Only override the resolution-based target if SOURCE_BITRATE_BPS is
                    # a meaningful non-zero value — a zero source bitrate (e.g. ffprobe
                    # returning 0 for WMV stream metadata) would corrupt the target and
                    # cause divide-by-zero in the quality optimization loop.
                    if (( $(echo "$(sanitize_value "${SOURCE_BITRATE_BPS:-0}") >= 100000" | bc -l 2>/dev/null || echo 0) )); then
                        TARGET_BITRATE_MBPS="$SOURCE_BITRATE_MBPS"
                        TARGET_BITRATE_BPS="$SOURCE_BITRATE_BPS"
                        LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.95" | bc | tr -d '\n\r')
                        UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.05" | bc | tr -d '\n\r')
                    fi
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
        if [ -z "$CROP_PARAMS" ] && (( $(echo "$(sanitize_value "$SOURCE_BITRATE_BPS") < $TARGET_BITRATE_BPS" | bc -l) )); then
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
                    # If codec incompatible, set up transcoding with source bitrate.
                    # Only override if SOURCE_BITRATE_BPS is a meaningful non-zero value.
                    if (( $(echo "$(sanitize_value "${SOURCE_BITRATE_BPS:-0}") >= 100000" | bc -l 2>/dev/null || echo 0) )); then
                        TARGET_BITRATE_MBPS="$SOURCE_BITRATE_MBPS"
                        TARGET_BITRATE_BPS="$SOURCE_BITRATE_BPS"
                        LOWER_BOUND=$(echo "$TARGET_BITRATE_BPS * 0.95" | bc | tr -d '\n\r')
                        UPPER_BOUND=$(echo "$TARGET_BITRATE_BPS * 1.05" | bc | tr -d '\n\r')
                    fi
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
        
        # If we reach here, source is outside tolerance and above target - show why we're transcoding
        if [ -n "$CROP_PARAMS" ]; then
            info "Source video bitrate: ${SOURCE_BITRATE_MBPS} Mbps"
            info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps"
            info "Re-encoding to apply crop..."
        elif [ -n "$SOURCE_BITRATE_BPS" ]; then
            local lower_bound_mbps=$(bps_to_mbps "$LOWER_BOUND")
            local upper_bound_mbps=$(bps_to_mbps "$UPPER_BOUND")
            info "Source video bitrate: ${SOURCE_BITRATE_MBPS} Mbps"
            info "Target bitrate: ${TARGET_BITRATE_MBPS} Mbps (acceptable range: ${lower_bound_mbps} - ${upper_bound_mbps} Mbps, ±5%)"
            if (( $(echo "$(sanitize_value "$SOURCE_BITRATE_BPS") > $UPPER_BOUND" | bc -l) )); then
                info "Source bitrate is above acceptable range. Transcoding to reduce file size..."
            else
                info "Source bitrate is outside acceptable range. Transcoding to optimize..."
            fi
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

    # A crop must produce exactly the expected frame size; anything else means a bad encode
    if [ -n "$CROP_PARAMS" ] && ! verify_crop_output "$temp_output_file" "$CROP_PARAMS"; then
        rm -f "$temp_output_file"
        cleanup_samples "$VIDEO_FILE"
        return 1
    fi
    
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
    # Always use ENCODED_OUTPUT_EXTENSION when transcoding (HEVC in MP4 container)
    if [ "$needs_transcode_for_compatibility" -eq 1 ]; then
        OUTPUT_FILE="${BASE_NAME}.orig.${actual_bitrate_mbps}.Mbps.${ENCODED_OUTPUT_EXTENSION}"
    else
        OUTPUT_FILE="${BASE_NAME}.fmpg.${actual_bitrate_mbps}.Mbps.${ENCODED_OUTPUT_EXTENSION}"
    fi
    
    # Rename temporary file to final filename
    mv "$temp_output_file" "$OUTPUT_FILE"

    if [ "${SUBTITLE_HAS_DROP_PENDING:-0}" -eq 1 ]; then
        SUBTITLE_DROP_FILES+=("$OUTPUT_FILE")
        SUBTITLE_HAS_DROP_PENDING=0
    fi

    # Clean up any remaining sample files
    cleanup_samples "$VIDEO_FILE"
    
    info "Transcoding complete!"
    info "Output file: $OUTPUT_FILE"
    info "Actual bitrate: ${actual_bitrate_mbps} Mbps"
    
    return 0
}

# Main entry point - orchestrates batch processing of all video files
#
# Entry point for the transcoding tool. Coordinates the complete workflow:
#   1. Parses command-line arguments
#   2. Runs preprocessing pass for non-QuickLook files
#   3. Discovers all video files in current directory and subdirectories
#   4. Processes each file through transcode_video()
#
# Arguments:
#   $@ - Command-line arguments (--target-bitrate, --max-depth, --auto-crop, --crop-detect-only, --help)
#
# Workflow:
#   - Sets up signal handlers for graceful interrupt handling
#   - Processes files in sorted alphabetical order (predictable)
#   - Provides progress indication (file N of M)
#   - Handles interruptions between files
#
# Exit codes:
#   0 - All files processed successfully
#   1 - No files found or processing error
#   130 - Interrupted by user (SIGINT)
#
# See docs/TECHNICAL.md for architecture overview
main() {
    # Parse command-line arguments
    parse_arguments "$@"

    SUBTITLE_DROP_FILES=()
    SUBTITLE_HAS_DROP_PENDING=0

    # Report-only mode: nothing is encoded, remuxed or renamed
    if [ "$CROP_DETECT_ONLY" -eq 1 ]; then
        run_crop_detect_only
        return 0
    fi

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
    
    if [ "${#SUBTITLE_DROP_FILES[@]}" -gt 0 ]; then
        warn ""
        warn "The following output files have no subtitles; the source file(s) had"
        warn "image-based subtitle streams (PGS/DVD) that cannot be converted to MP4:"
        for _drop_file in "${SUBTITLE_DROP_FILES[@]}"; do
            warn "  $_drop_file"
        done
        warn "Original files are preserved — use remux-select-audio.sh to keep"
        warn "image-based subtitles in MKV output."
    fi

    info ""
    info "Batch processing complete! Processed ${total_files} file(s)"
}

# Run main function (unless in test mode)
if [ -z "${BOILER_TEST_MODE:-}" ]; then
    main "$@"
fi

