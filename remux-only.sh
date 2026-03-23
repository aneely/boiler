#!/bin/bash

# Standalone script to remux video files to MP4 for QuickLook compatibility
# Only remuxes (no transcoding) - converts container format
# Processes non-QuickLook compatible formats: mkv, wmv, avi, webm, flv, mpg, mpeg, ts
# Also checks existing .mp4 files and re-muxes any that are not QuickLook-compatible
# (wrong HEVC tag or QuickLook-unfriendly audio codec)
# Supports configurable subdirectory depth traversal (default: 2 levels deep)

set -e

# Global max depth for directory traversal (default: 2 = current directory + one subdirectory level)
# Set to 0 for unlimited depth (full recursive search)
# Only set default if not already set (allows environment variable override for testing)
GLOBAL_MAX_DEPTH="${GLOBAL_MAX_DEPTH:-2}"

# Global flag for preserve-name mode (default: 0 = use .orig.{bitrate}.Mbps naming)
# When set to 1, output keeps original base name with .mp4 extension (no boiler markers)
GLOBAL_PRESERVE_NAME="${GLOBAL_PRESERVE_NAME:-0}"

# Global array for specified files from command-line arguments
SPECIFIED_FILES=()

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

    case "$codec_lower" in
        wmav1|wmav2|wmalossless|wmapro|vorbis|adpcm_ms)
            return 1  # Not compatible with MP4
            ;;
        *)
            return 0
            ;;
    esac
}

# Check if audio codec is known to play in macOS QuickLook
# Stricter than is_audio_codec_mp4_compatible() — some MP4-muxable codecs
# (e.g. AC3, EAC3, Opus, FLAC) may mux successfully but produce silent audio in QuickLook.
# Uses a whitelist of confirmed-compatible codecs; anything unknown is treated as incompatible.
# Arguments: codec_name
# Returns: 0 if QuickLook-compatible, 1 if not
is_audio_codec_quicklook_compatible() {
    local codec="$1"
    local codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')

    case "$codec_lower" in
        aac|mp3|mp3float|alac)
            return 0  # Confirmed QuickLook-compatible
            ;;
        *)
            return 1  # Not confirmed; re-encode to AAC for safety
            ;;
    esac
}

# Check if an MP4 file is QuickLook-compatible
# Checks: (1) HEVC files must have hvc1 tag, (2) audio codec must be QuickLook-playable
# Arguments: file_path
# Returns: 0 if compatible, 1 if not compatible or on error
is_quicklook_compatible() {
    local file_path="$1"

    local video_codec
    video_codec=$(get_video_codec "$file_path" 2>/dev/null) || return 1
    local codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')

    # Check HEVC tag — hvc1 required for QuickLook; hev1 causes playback failures
    if [ "$codec_lower" = "hevc" ] || [ "$codec_lower" = "h265" ]; then
        local codec_tag
        codec_tag=$(get_video_codec_tag "$file_path")
        local tag_lower=$(echo "$codec_tag" | tr '[:upper:]' '[:lower:]')
        if [ "$tag_lower" != "hvc1" ]; then
            return 1
        fi
    fi

    # Check audio codec
    local audio_codec
    audio_codec=$(get_audio_codec "$file_path")
    if [ -n "$audio_codec" ]; then
        if ! is_audio_codec_quicklook_compatible "$audio_codec"; then
            return 1
        fi
    fi

    return 0
}

# Determine audio codec argument for ffmpeg based on source audio compatibility
# Returns "copy" if audio can be copied into MP4, "aac" if it must be re-encoded
# Arguments: file_path
# Returns: "copy" or "aac" (printed to stdout)
get_audio_codec_arg() {
    local file_path="$1"
    local audio_codec
    audio_codec=$(get_audio_codec "$file_path")

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

# Get video codec tag string from a video file (e.g. hvc1, hev1, avc1)
# Arguments: file_path
# Returns: codec tag string (or empty if unavailable)
get_video_codec_tag() {
    local file_path="$1"
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$file_path" 2>/dev/null | head -1 | tr -d '\n\r'
}

# Check if a file is a non-QuickLook compatible format
is_non_quicklook_format() {
    local file="$1"
    local ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    
    case "$ext" in
        mkv|wmv|avi|webm|flv|mpg|mpeg|ts)
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
    
    # Build ffmpeg command: explicit stream mapping (first video + all audio) then copy
    # Without -map, FFmpeg default stream selection picks only one audio track; mapping all preserves multi-track audio
    local num_audio
    num_audio=$(count_audio_streams "$input_file")
    local audio_codec_arg
    audio_codec_arg=$(get_audio_codec_arg "$input_file")
    local ffmpeg_args=(-i "$input_file" -map 0:v:0)
    [ "$num_audio" -gt 0 ] && ffmpeg_args+=(-map 0:a)
    ffmpeg_args+=(-c:v copy -c:a "$audio_codec_arg" -movflags +faststart)
    
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

Remux video files to MP4 for QuickLook compatibility (no transcoding).

OPTIONS:
    -L, --max-depth DEPTH        Maximum directory depth to traverse
                                 Example: --max-depth 3
                                 Default: 2 (current directory + one subdirectory level)
                                 Use 0 for unlimited depth (full recursive search)
                                 Only applies when FILE arguments are not provided

    -p, --preserve-name          Keep original filename (output: {base}.mp4)
                                 Without this flag: output is {base}.orig.{bitrate}.Mbps.mp4
                                 If {base}.mp4 already exists, falls back to {base}.remux.mp4

    -h, --help                   Show this help message and exit

If FILE arguments are provided, processes only those files.
Otherwise, processes all non-QuickLook compatible video files and all .mp4 files
in the current directory and subdirectories (default: one level deep, configurable
via -L/--max-depth).

Non-QuickLook formats remuxed: mkv, wmv, avi, webm, flv, mpg, mpeg, ts
  (only if codec is MP4-compatible)
.mp4 files checked and re-muxed if not QuickLook-compatible:
  - HEVC files missing the hvc1 tag
  - Audio codec not playable in QuickLook (anything other than AAC, MP3, ALAC)
  - .mp4 files with boiler markers (.fmpg., .orig., .hbrk.) are skipped

EXAMPLES:
    # Process all files in current directory (2 levels deep)
    $0

    # Process only current directory (no subdirectories)
    $0 -L 1

    # Process three levels deep
    $0 -L 3

    # Process all subdirectories recursively (unlimited depth)
    $0 -L 0

    # Remux without boiler naming (keeps original name, just changes extension)
    $0 --preserve-name

    # Process specific files
    $0 video1.mkv video2.avi movie.mp4

The script will:
1. Check codec compatibility (skips incompatible codecs like WMV3)
2. Measure source bitrate
3. Remux to MP4 with QuickLook compatibility
4. Rename to: {base}.orig.{bitrate}.Mbps.mp4 (or {base}.mp4 with --preserve-name)
5. Remove original file (only if remux succeeds)
EOF
}

# Parse command-line arguments
# Sets global variables GLOBAL_MAX_DEPTH, GLOBAL_PRESERVE_NAME, and SPECIFIED_FILES
parse_arguments() {
    SPECIFIED_FILES=()

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
            -p|--preserve-name)
                GLOBAL_PRESERVE_NAME=1
                shift
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
                SPECIFIED_FILES+=("$1")
                shift
                ;;
        esac
    done
}

# Find all non-QuickLook format files for remuxing
# Uses GLOBAL_MAX_DEPTH to control directory traversal depth
# Prints found file paths, one per line (sorted)
find_remux_files() {
    local non_quicklook_extensions=("mkv" "wmv" "avi" "webm" "flv" "mpg" "mpeg" "ts")
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"
    local all_files=()

    for ext in "${non_quicklook_extensions[@]}"; do
        if [ "$max_depth" -eq 0 ]; then
            while IFS= read -r found; do
                if [ -n "$found" ] && [ -f "$found" ]; then
                    all_files+=("$found")
                fi
            done < <(find . -type f -iname "*.${ext}" 2>/dev/null)
        else
            while IFS= read -r found; do
                if [ -n "$found" ] && [ -f "$found" ]; then
                    all_files+=("$found")
                fi
            done < <(find . -maxdepth "${max_depth}" -type f -iname "*.${ext}" 2>/dev/null)
        fi
    done

    # Print sorted results
    if [ ${#all_files[@]} -gt 0 ]; then
        printf '%s\n' "${all_files[@]}" | sort
    fi
}

# Find .mp4 files without boiler markers for QuickLook compatibility checking
# Uses GLOBAL_MAX_DEPTH to control directory traversal depth
# Prints found file paths, one per line (sorted)
find_mp4_files() {
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"
    local all_files=()

    if [ "$max_depth" -eq 0 ]; then
        while IFS= read -r found; do
            if [ -n "$found" ] && [ -f "$found" ]; then
                all_files+=("$found")
            fi
        done < <(find . -type f -iname "*.mp4" 2>/dev/null)
    else
        while IFS= read -r found; do
            if [ -n "$found" ] && [ -f "$found" ]; then
                all_files+=("$found")
            fi
        done < <(find . -maxdepth "${max_depth}" -type f -iname "*.mp4" 2>/dev/null)
    fi

    # Filter out files with boiler markers
    local filtered=()
    for f in "${all_files[@]}"; do
        local bn
        bn=$(basename "$f")
        if [[ "$bn" != *.fmpg.* ]] && [[ "$bn" != *.orig.* ]] && [[ "$bn" != *.hbrk.* ]]; then
            filtered+=("$f")
        fi
    done

    if [ ${#filtered[@]} -gt 0 ]; then
        printf '%s\n' "${filtered[@]}" | sort
    fi
}

# Generate output filename based on preserve-name mode
# Arguments: dirname, base_name, source_bitrate_mbps
# Prints the output filename to stdout
generate_output_filename() {
    local dirname="$1"
    local base_name="$2"
    local source_bitrate_mbps="$3"
    local prefix=""
    [ "$dirname" != "." ] && prefix="${dirname}/"

    if [ "$GLOBAL_PRESERVE_NAME" -eq 1 ]; then
        local output_file="${prefix}${base_name}.mp4"
        if [ -f "$output_file" ]; then
            output_file="${prefix}${base_name}.remux.mp4"
        fi
        echo "$output_file"
    else
        echo "${prefix}${base_name}.orig.${source_bitrate_mbps}.Mbps.mp4"
    fi
}

# Process a single file: measure bitrate, generate output path, remux, remove original.
# Used by both the non-QuickLook and .mp4 processing loops.
# Directly modifies processed_count, skipped_count, failed_count from the calling scope
# (bash dynamic scoping — must be called from main(), not a subshell).
# Arguments: file_path
process_one_file() {
    local file_path="$1"
    local basename=$(basename "$file_path")
    local dirname=$(dirname "$file_path")

    local video_duration
    if ! video_duration=$(get_video_duration "$file_path" 2>/dev/null); then
        error "  Could not determine duration, skipping"
        skipped_count=$((skipped_count + 1))
        return
    fi

    local source_bitrate_bps
    if ! source_bitrate_bps=$(measure_bitrate "$file_path" "$video_duration"); then
        error "  Could not determine bitrate, skipping"
        skipped_count=$((skipped_count + 1))
        return
    fi

    local source_bitrate_mbps=$(bps_to_mbps "$source_bitrate_bps")

    parse_filename "$file_path"
    local base_name="$BASE_NAME"
    local output_file
    output_file=$(generate_output_filename "$dirname" "$base_name" "$source_bitrate_mbps")

    if [ -f "$output_file" ]; then
        warn "  Output file already exists: $output_file, skipping"
        skipped_count=$((skipped_count + 1))
        return
    fi

    info "  Remuxing to: $(basename "$output_file")"
    if remux_to_mp4 "$file_path" "$output_file"; then
        rm -f "$file_path"
        info "  ✓ Successfully remuxed and removed original"
        processed_count=$((processed_count + 1))
    else
        error "  ✗ Remux failed, original file preserved"
        rm -f "$output_file"
        failed_count=$((failed_count + 1))
    fi
    echo ""
}

# Main function
main() {
    # Check requirements
    check_requirements

    # Parse arguments
    parse_arguments "$@"

    local remux_files=()
    local mp4_files=()

    # If files were specified, route each to the appropriate list
    if [ ${#SPECIFIED_FILES[@]} -gt 0 ]; then
        for file in "${SPECIFIED_FILES[@]}"; do
            if [ -f "$file" ]; then
                local ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
                if is_non_quicklook_format "$file"; then
                    remux_files+=("$file")
                elif [ "$ext" = "mp4" ]; then
                    mp4_files+=("$file")
                else
                    warn "Skipping $file: Not a supported format"
                fi
            else
                warn "File not found: $file"
            fi
        done
    else
        while IFS= read -r found; do
            remux_files+=("$found")
        done < <(find_remux_files)
        while IFS= read -r found; do
            mp4_files+=("$found")
        done < <(find_mp4_files)
    fi

    local total=$(( ${#remux_files[@]} + ${#mp4_files[@]} ))
    if [ "$total" -eq 0 ]; then
        info "No files to process"
        exit 0
    fi

    local processed_count=0
    local skipped_count=0
    local failed_count=0

    # Phase 1: remux non-QuickLook formats to MP4
    if [ ${#remux_files[@]} -gt 0 ]; then
        info "Found ${#remux_files[@]} non-QuickLook file(s) to remux..."
        echo ""

        for file_path in "${remux_files[@]}"; do
            local basename=$(basename "$file_path")
            info "Processing: $basename"

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

            process_one_file "$file_path"
        done
    fi

    # Phase 2: check .mp4 files for QuickLook compatibility; re-mux if needed
    if [ ${#mp4_files[@]} -gt 0 ]; then
        info "Found ${#mp4_files[@]} .mp4 file(s) to check for QuickLook compatibility..."
        echo ""

        for file_path in "${mp4_files[@]}"; do
            local basename=$(basename "$file_path")
            info "Checking: $basename"

            if is_quicklook_compatible "$file_path"; then
                info "  Already QuickLook-compatible, skipping"
                skipped_count=$((skipped_count + 1))
                echo ""
                continue
            fi

            info "  Not QuickLook-compatible, remuxing..."

            # Phase 2 follows the remux-select-audio pattern: output {base}.remux.mp4,
            # original is never deleted — user verifies and cleans up manually.
            parse_filename "$file_path"
            local base_name="$BASE_NAME"
            local dirname=$(dirname "$file_path")
            local prefix=""
            [ "$dirname" != "." ] && prefix="${dirname}/"
            local output_file="${prefix}${base_name}.remux.mp4"

            if [ -f "$output_file" ]; then
                warn "  Output file already exists: $output_file, skipping"
                skipped_count=$((skipped_count + 1))
                echo ""
                continue
            fi

            info "  Remuxing to: $(basename "$output_file")"
            if remux_to_mp4 "$file_path" "$output_file"; then
                info "  ✓ Remuxed to $(basename "$output_file") (original preserved)"
                processed_count=$((processed_count + 1))
            else
                error "  ✗ Remux failed, original file preserved"
                rm -f "$output_file"
                failed_count=$((failed_count + 1))
            fi
            echo ""
        done
    fi

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

# Run main function (unless in test mode)
if [ -z "${REMUX_TEST_MODE:-}" ]; then
    main "$@"
fi
