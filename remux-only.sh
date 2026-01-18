#!/bin/bash

# Standalone script to remux video files to MP4 with .orig.{bitrate}.Mbps naming
# Only remuxes (no transcoding) - converts container format for QuickLook compatibility
# Processes non-QuickLook compatible formats: mkv, wmv, avi, webm, flv
# Supports configurable subdirectory depth traversal (default: 2 levels deep)

set -e

# Global max depth for directory traversal (default: 2 = current directory + one subdirectory level)
# Set to 0 for unlimited depth (full recursive search)
# Only set default if not already set (allows environment variable override for testing)
GLOBAL_MAX_DEPTH="${GLOBAL_MAX_DEPTH:-2}"

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

# Sanitize value for bc calculations (remove newlines, carriage returns, and trim whitespace)
sanitize_value() {
    echo "$1" | tr -d '\n\r' | xargs
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

# Get video codec using ffprobe
get_video_codec() {
    local video_file="$1"
    local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null | head -1 | tr -d '\n\r')

    if [ -z "$codec" ]; then
        error "Could not determine video codec"
        return 1
    fi

    echo "$codec"
}

# Check if a video codec can be copied into MP4 container without transcoding
is_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    
    # Incompatible codecs that cannot be copied into MP4
    case "$codec_lower" in
        wmv3|wmv1|wmv2|vc1|rv40|rv30|theora)
            return 1  # Incompatible
            ;;
        *)
            return 0  # Compatible (h264, hevc, h265, mpeg4, avc1, etc.)
            ;;
    esac
}

# Check if a file is a non-QuickLook compatible format
is_non_quicklook_format() {
    local file="$1"
    local ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    
    case "$ext" in
        mkv|wmv|avi|webm|flv)
            return 0  # Non-QuickLook format
            ;;
        *)
            return 1  # QuickLook compatible format
            ;;
    esac
}

# Get video duration using ffprobe
get_video_duration() {
    local video_file="$1"
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null | head -1 | tr -d '\n\r')

    if [ -z "$duration" ]; then
        error "Could not determine video duration"
        return 1
    fi

    echo "$duration"
}

# Measure bitrate from a video file
# Arguments: file_path, duration_seconds
# Returns: bitrate in bits per second, or empty string if unavailable
measure_bitrate() {
    local file_path="$1"
    local duration="$2"
    
    # Try to get bitrate from stream info first (most accurate)
    local stream_bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r')
    
    if [ -n "$stream_bitrate" ] && [ "$stream_bitrate" != "N/A" ] && [ "$stream_bitrate" != "0" ]; then
        echo "$stream_bitrate"
        return 0
    fi
    
    # Fallback: calculate from file size
    if [ -n "$duration" ] && [ "$(echo "$duration > 0" | bc -l)" -eq 1 ]; then
        local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null)
        if [ -n "$file_size" ] && [ "$file_size" -gt 0 ]; then
            # Calculate bitrate: (file_size_bytes * 8) / duration_seconds
            local file_size_clean=$(sanitize_value "$file_size")
            local duration_clean=$(sanitize_value "$duration")
            local calculated_bitrate=$(echo "scale=0; ($file_size_clean * 8) / $duration_clean" | bc | tr -d '\n\r')
            echo "$calculated_bitrate"
            return 0
        fi
    fi
    
    return 1
}

# Convert bitrate from bits per second to megabits per second (with 2 decimal places)
bps_to_mbps() {
    local bps=$(sanitize_value "$1")
    echo "scale=2; $bps / 1000000" | bc | tr -d '\n\r'
}

# Remux video file to MP4 with QuickLook compatibility
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
        warn "Video codec '$video_codec' is not compatible with MP4 container (cannot be copied without transcoding). Skipping $input_file"
        return 1
    fi
    
    # Build ffmpeg command: copy all streams, add QuickLook compatibility flags
    local ffmpeg_args=(-i "$input_file" -c:v copy -c:a copy -movflags +faststart)
    
    # Add HEVC tag if video codec is HEVC/H.265 for QuickLook compatibility
    local codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')
    if [ "$codec_lower" = "hevc" ] || [ "$codec_lower" = "h265" ]; then
        ffmpeg_args+=(-tag:v hvc1)
    fi
    
    # Add output format and file
    ffmpeg_args+=(-f mp4 "$output_file")
    
    # Execute ffmpeg command
    ffmpeg "${ffmpeg_args[@]}" -loglevel info -stats
}

# Parse filename into base name and extension
# Sets global variables BASE_NAME and FILE_EXTENSION
parse_filename() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    # Find last dot (extension separator)
    if [[ "$basename" == *.* ]]; then
        BASE_NAME="${basename%.*}"
        FILE_EXTENSION="${basename##*.}"
    else
        BASE_NAME="$basename"
        FILE_EXTENSION="$basename"
    fi
}

# Show usage information
show_usage() {
    cat >&2 <<EOF
Usage: $0 [OPTIONS] [FILE...]

Remux video files to MP4 with .orig.{bitrate}.Mbps naming (no transcoding).

OPTIONS:
    -L, --max-depth DEPTH        Maximum directory depth to traverse
                                 Example: --max-depth 3
                                 Default: 2 (current directory + one subdirectory level)
                                 Use 0 for unlimited depth (full recursive search)
                                 Only applies when FILE arguments are not provided

    -h, --help                   Show this help message and exit

If FILE arguments are provided, processes only those files.
Otherwise, processes all non-QuickLook compatible video files in the current directory
and subdirectories (default: one level deep, configurable via -L/--max-depth).

Supported formats: mkv, wmv, avi, webm, flv (only if codec is MP4-compatible)

EXAMPLES:
    # Process all compatible files in current directory (2 levels deep)
    $0

    # Process only current directory (no subdirectories)
    $0 -L 1

    # Process three levels deep
    $0 -L 3

    # Process all subdirectories recursively (unlimited depth)
    $0 -L 0

    # Process specific files
    $0 video1.mkv video2.avi

The script will:
1. Check codec compatibility (skips incompatible codecs like WMV3)
2. Measure source bitrate
3. Remux to MP4 with QuickLook compatibility
4. Rename to: {base}.orig.{bitrate}.Mbps.mp4
5. Remove original file (only if remux succeeds)
EOF
}

# Parse command-line arguments
# Sets global variable GLOBAL_MAX_DEPTH if -L or --max-depth is provided
# Returns: list of file arguments (one per line)
parse_arguments() {
    local files=()
    
    while [ $# -gt 0 ]; do
        case "$1" in
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
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                error "Error: Unknown option '$1'"
                error "Use --help for usage information"
                exit 1
                ;;
            *)
                files+=("$1")
                ;;
        esac
    done
    
    # Return files array (will be captured by caller)
    printf '%s\n' "${files[@]}"
}

# Main function
main() {
    # Check requirements
    check_requirements
    
    # Parse arguments
    local specified_files
    specified_files=$(parse_arguments "$@")
    
    # Non-QuickLook format extensions
    local non_quicklook_extensions=("mkv" "wmv" "avi" "webm" "flv")
    local files_to_process=()
    
    # If files were specified, use those; otherwise find files
    if [ -n "$specified_files" ]; then
        # Process specified files
        while IFS= read -r file; do
            if [ -n "$file" ] && [ -f "$file" ]; then
                if is_non_quicklook_format "$file"; then
                    files_to_process+=("$file")
                else
                    warn "Skipping $file: Not a non-QuickLook format (mkv, wmv, avi, webm, flv)"
                fi
            elif [ -n "$file" ]; then
                warn "File not found: $file"
            fi
        done <<< "$specified_files"
    else
        # Find all non-QuickLook format files in current directory and subdirectories
        local max_depth="${GLOBAL_MAX_DEPTH:-2}"
        
        for ext in "${non_quicklook_extensions[@]}"; do
            # Use -maxdepth only if depth is not 0 (unlimited)
            if [ "$max_depth" -eq 0 ]; then
                while IFS= read -r found; do
                    if [ -n "$found" ] && [ -f "$found" ]; then
                        files_to_process+=("$found")
                    fi
                done < <(find . -type f -iname "*.${ext}" 2>/dev/null)
            else
                while IFS= read -r found; do
                    if [ -n "$found" ] && [ -f "$found" ]; then
                        files_to_process+=("$found")
                    fi
                done < <(find . -maxdepth "${max_depth}" -type f -iname "*.${ext}" 2>/dev/null)
            fi
        done
    fi
    
    if [ ${#files_to_process[@]} -eq 0 ]; then
        info "No files to process"
        exit 0
    fi
    
    info "Found ${#files_to_process[@]} file(s) to remux..."
    echo ""
    
    local processed_count=0
    local skipped_count=0
    local failed_count=0
    
    # Process each file
    for file_path in "${files_to_process[@]}"; do
        local basename=$(basename "$file_path")
        local dirname=$(dirname "$file_path")
        
        info "Processing: $basename"
        
        # Check codec compatibility first
        local video_codec
        if ! video_codec=$(get_video_codec "$file_path" 2>/dev/null); then
            error "  Could not detect codec, skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        if ! is_codec_mp4_compatible "$video_codec"; then
            warn "  Codec '$video_codec' is not MP4-compatible, skipping (would require transcoding)"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Get video duration and bitrate
        local video_duration
        if ! video_duration=$(get_video_duration "$file_path" 2>/dev/null); then
            error "  Could not determine duration, skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        local source_bitrate_bps
        if ! source_bitrate_bps=$(measure_bitrate "$file_path" "$video_duration"); then
            error "  Could not determine bitrate, skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        local source_bitrate_mbps=$(bps_to_mbps "$source_bitrate_bps")
        
        # Parse filename
        parse_filename "$file_path"
        local base_name="$BASE_NAME"
        
        # Generate output filename: {base}.orig.{bitrate}.Mbps.mp4
        local output_file
        if [ "$dirname" != "." ]; then
            output_file="${dirname}/${base_name}.orig.${source_bitrate_mbps}.Mbps.mp4"
        else
            output_file="${base_name}.orig.${source_bitrate_mbps}.Mbps.mp4"
        fi
        
        # Check if output file already exists
        if [ -f "$output_file" ]; then
            warn "  Output file already exists: $output_file, skipping"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        # Remux to MP4
        info "  Remuxing to: $(basename "$output_file")"
        if remux_to_mp4 "$file_path" "$output_file"; then
            # Remove original file only if remux succeeded
            rm -f "$file_path"
            info "  ✓ Successfully remuxed and removed original"
            processed_count=$((processed_count + 1))
        else
            error "  ✗ Remux failed, original file preserved"
            rm -f "$output_file"  # Clean up partial output
            failed_count=$((failed_count + 1))
        fi
        echo ""
    done
    
    # Summary
    echo ""
    info "Summary:"
    info "  Processed: $processed_count"
    if [ $skipped_count -gt 0 ]; then
        warn "  Skipped: $skipped_count"
    fi
    if [ $failed_count -gt 0 ]; then
        error "  Failed: $failed_count"
        exit 1
    fi
}

# Run main function
main "$@"
