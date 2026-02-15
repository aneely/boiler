#!/bin/bash

# Remux with audio track selection. Lists audio tracks, lets the user choose which
# to keep, and remuxes to a Boiler-compatible file (stream copy, no transcoding).
# Accepts one or more video files or directories; for each file, prompts for audio
# selection before proceeding. Output container matches input (e.g. MKV→MKV) so
# all subtitles are preserved; use case: drop commentary or extra language tracks.

set -e

# Global max depth for directory traversal (default: 2 = current directory + one subdirectory level).
# Set to 0 for unlimited depth. Only set default if not already set (allows env override for testing).
GLOBAL_MAX_DEPTH="${GLOBAL_MAX_DEPTH:-2}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Validate depth value: non-empty, non-negative integer (0 = unlimited).
# Returns 0 if valid, 1 if invalid.
validate_depth() {
    local depth="$1"
    if [ -z "$depth" ]; then
        return 1
    fi
    if ! echo "$depth" | grep -qE '^[0-9]+$'; then
        return 1
    fi
    return 0
}

show_usage() {
    cat >&2 <<EOF
Usage: $0 [-h] [-L DEPTH] [path ...]

Remux video file(s) with selected audio tracks only (no transcoding).
Each path may be a video file or a directory (searched for video files).
Lists audio streams, prompts for which to keep per file, and writes a
Boiler-compatible file. Output container matches input (e.g. MKV→MKV, MP4→MP4).

With no path arguments, processes the current directory (and subdirectories
according to -L/--max-depth).

OPTIONS:
    -h, --help           Show this help and exit
    -L, --max-depth DEPTH  Maximum directory depth to traverse (default: 2).
                           Default 2 = current directory + one subdirectory level.
                           Use 0 for unlimited depth (full recursive).

EXAMPLES:
    $0                        # Current directory, two levels deep
    $0 -L 1                   # Current directory only (no subdirs)
    $0 -L 0                   # Current directory, all subdirs recursively
    $0 dir1 file.mkv          # Explicit path(s)

Output: same directory as input, {base}.remux.{ext}. On FFmpeg failure,
failed output is removed and original kept.
EOF
}

# Get video codec using ffprobe (same logic as remux-only.sh)
get_video_codec() {
    local video_file="$1"
    local codec
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null | head -1 | tr -d '\n\r')
    if [ -z "$codec" ]; then
        error "Could not determine video codec"
        return 1
    fi
    echo "$codec"
}

# Count video streams (for safe HEVC tagging: only tag when exactly one video stream)
count_video_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        echo "0"
        return 0
    fi
    local n=0
    for _ in $(echo "$csv" | tr ',' ' '); do n=$((n + 1)); done
    echo "$n"
}

# Check if video codec can be copied into MP4 (same as remux-only.sh)
is_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower
    codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    case "$codec_lower" in
        wmv3|wmv1|wmv2|vc1|rv40|rv30|theora) return 1 ;;
        *) return 0 ;;
    esac
}

# Probe subtitle streams: output one codec_name per line (order = 0-based subtitle index).
# Used to only map MP4-compatible subtitle codecs (e.g. mov_text); subrip/srt cannot be stream-copied into MP4.
probe_subtitle_codecs() {
    local input="$1"
    ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 "$input" 2>/dev/null || true
}

# Return 0 if subtitle codec can be stream-copied into MP4, 1 otherwise (e.g. subrip/srt cannot).
is_subtitle_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower
    codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    case "$codec_lower" in
        mov_text) return 0 ;;
        *) return 1 ;;
    esac
}

# Get output format and extension from input path. Echo "format_name ext" (e.g. "matroska mkv" or "mp4 mp4").
# Same container as input preserves all subtitle codecs (e.g. SubRip in MKV); unknown defaults to matroska.
get_output_format_from_input() {
    local input_path="$1"
    local ext
    ext=$(echo "${input_path##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mkv)   echo "matroska mkv" ;;
        mp4|m4v|mov) echo "mp4 mp4" ;;
        webm)  echo "webm webm" ;;
        *)     echo "matroska mkv" ;;
    esac
}

check_requirements() {
    if ! command -v ffmpeg &> /dev/null; then
        error "ffmpeg is not installed or not in PATH"
        exit 1
    fi
    if ! command -v ffprobe &> /dev/null; then
        error "ffprobe is not installed or not in PATH"
        exit 1
    fi
}

# Common video extensions for file discovery (directories)
VIDEO_EXTENSIONS=(mkv mp4 m4v mov webm avi wmv flv mpg mpeg ts m2ts)

# Return 0 if path has a video extension (case-insensitive), 1 otherwise.
is_video_file() {
    local path="$1"
    local ext
    ext=$(echo "${path##*.}" | tr '[:upper:]' '[:lower:]')
    local e
    for e in "${VIDEO_EXTENSIONS[@]}"; do
        if [ "$ext" = "$e" ]; then return 0; fi
    done
    return 1
}

# Collect video file paths from args (files and/or directories). Uses GLOBAL_MAX_DEPTH
# for directory traversal (default 2 = dir + one subdir level; 0 = unlimited).
# Echo one path per line.
collect_video_files() {
    local -a all=()
    local arg
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"
    for arg in "$@"; do
        if [ -f "$arg" ]; then
            if is_video_file "$arg"; then
                all+=("$arg")
            else
                warn "Skipping (not a video file): $arg"
            fi
        elif [ -d "$arg" ]; then
            local -a dirs=()
            if [ "$max_depth" -eq 0 ]; then
                dirs=("$arg")
                while IFS= read -r d; do
                    [ -n "$d" ] && [ -d "$d" ] && dirs+=("$d")
                done < <(find "$arg" -type d ! -path "$arg" 2>/dev/null)
            else
                dirs=("$arg")
                local subdir_depth=$((max_depth - 1))
                if [ "$subdir_depth" -gt 0 ]; then
                    while IFS= read -r d; do
                        [ -n "$d" ] && [ -d "$d" ] && dirs+=("$d")
                    done < <(find "$arg" -mindepth 1 -maxdepth "$subdir_depth" -type d 2>/dev/null)
                fi
            fi
            local d ext
            for d in "${dirs[@]}"; do
                for ext in "${VIDEO_EXTENSIONS[@]}"; do
                    while IFS= read -r -d '' f; do
                        [ -n "$f" ] && [ -f "$f" ] && all+=("$f")
                    done < <(find "$d" -maxdepth 1 -type f -iname "*.${ext}" -print0 2>/dev/null | sort -z)
                done
            done
        else
            warn "Not a file or directory, skipping: $arg"
        fi
    done
    printf '%s\n' "${all[@]}"
}

# Process one video file: prompt for audio selection, remux. Return 0 on success or
# nothing-to-do, 1 on failure. On FFmpeg failure, removes failed output if present.
process_one_file() {
    local input_file="$1"
    if [ ! -f "$input_file" ]; then
        error "File not found: $input_file"
        return 1
    fi

    # Output container matches input so all subtitles can be preserved (e.g. SubRip in MKV).
    local output_format output_ext
    read -r output_format output_ext <<< "$(get_output_format_from_input "$input_file")"

    local num_audio
    num_audio=$(count_audio_streams "$input_file")
    if [ "$num_audio" -eq 0 ]; then
        info "No audio tracks to select. Nothing to do."
        return 0
    fi
    if [ "$num_audio" -eq 1 ]; then
        info "Only one audio track; nothing to select. Nothing to do."
        return 0
    fi

    # Get video codec; only enforce MP4 compatibility when output is MP4
    local video_codec
    video_codec=$(get_video_codec "$input_file") || return 1
    if [ "$output_format" = "mp4" ] && ! is_codec_mp4_compatible "$video_codec"; then
        error "Video codec '$video_codec' is not compatible with MP4 container (cannot copy without transcoding)."
        return 1
    fi

    # Build list of video streams for header display
    local -a video_labels
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        video_labels+=("$line")
    done < <(probe_video_streams "$input_file")

    # Build list of audio streams (labels only; position is 0-based audio index for -map 0:a:N)
    local -a labels
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        labels+=("$line")
    done < <(probe_audio_streams "$input_file")

    # Display 1-based list: video streams first, then audio tracks
    echo ""
    if [ ${#video_labels[@]} -gt 0 ]; then
        info "Video streams:"
        for j in "${!video_labels[@]}"; do
            echo "  $((j + 1)): ${video_labels[$j]}"
        done
        echo ""
    fi
    info "Audio tracks:"
    for j in "${!labels[@]}"; do
        echo "  $((j + 1)): ${labels[$j]}"
    done
    echo ""
    printf "Audio tracks to keep (e.g. 1,3 or 'all'): "
    read -r user_input || true
    user_input=$(echo "$user_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Parse selection -> 0-based audio indices for -map 0:a:N
    local -a selected=()
    if [ -z "$user_input" ] || [ "$user_input" = "all" ]; then
        for j in "${!labels[@]}"; do selected+=("$j"); done
    else
        local raw tok one_based zero_based seen s
        raw=$(echo "$user_input" | tr ',' ' ')
        for tok in $raw; do
            if ! echo "$tok" | grep -qE '^[0-9]+$'; then
                error "Invalid input: '$tok' is not a number."
                return 1
            fi
            one_based=$tok
            if [ "$one_based" -lt 1 ] || [ "$one_based" -gt "${#labels[@]}" ]; then
                error "Track number $one_based is out of range (1 to ${#labels[@]})."
                return 1
            fi
            zero_based=$((one_based - 1))
            seen=0
            for s in "${selected[@]}"; do
                if [ "$s" = "$zero_based" ]; then seen=1; break; fi
            done
            [ "$seen" -eq 0 ] && selected+=("$zero_based")
        done
    fi

    if [ ${#selected[@]} -eq 0 ]; then
        error "You must keep at least one audio track (or use 'all')."
        return 1
    fi

    # Keep-all = no-op: no remux when user chose to keep every audio track
    if [ ${#selected[@]} -eq ${#labels[@]} ]; then
        info "Keeping all audio tracks; nothing to do."
        return 0
    fi

    # MP4 + multiple video streams: warn and require explicit confirmation before stripping to first video only
    local num_video
    num_video=$(count_video_streams "$input_file")
    if [ "$output_format" = "mp4" ] && [ "$num_video" -gt 1 ]; then
        warn "Only the first video stream will be included; other video streams (e.g. cover art) will be dropped."
        printf "Type 'yes' to continue: "
        read -r confirm || true
        if [ "$confirm" != "yes" ]; then
            info "Aborted."
            return 0
        fi
    fi

    # Output path: same directory, {base}.remux.{ext} (ext matches input container)
    local dirname base_name
    dirname=$(dirname "$input_file")
    base_name=$(basename "$input_file")
    base_name="${base_name%.*}"
    if [ -z "$base_name" ]; then
        base_name="output"
    fi
    local output_file
    if [ "$dirname" = "." ]; then
        output_file="${base_name}.remux.${output_ext}"
    else
        output_file="${dirname}/${base_name}.remux.${output_ext}"
    fi

    if [ "$output_file" = "$input_file" ]; then
        error "Output path would overwrite input file. Aborting."
        return 1
    fi
    if [ -f "$output_file" ]; then
        error "Output file already exists: $output_file. Remove it or choose a different source. Aborting."
        return 1
    fi

    # Build ffmpeg: -i input, video map (MP4: first only; non-MP4: only streams with valid dimensions to avoid attached-pic mux errors), -map 0:a:N, then subtitles
    local -a ffmpeg_args=(-i "$input_file")
    if [ "$output_format" = "mp4" ]; then
        ffmpeg_args+=(-map 0:v:0)
    else
        local -a muxable_v
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            muxable_v+=("$n")
        done < <(get_muxable_video_stream_indices "$input_file")
        if [ ${#muxable_v[@]} -eq 0 ]; then
            error "No video streams with valid dimensions found (e.g. only attached pictures)."
            return 1
        fi
        for n in "${muxable_v[@]}"; do
            ffmpeg_args+=(-map "0:v:$n")
        done
    fi
    for n in "${selected[@]}"; do
        ffmpeg_args+=(-map "0:a:$n")
    done
    if [ "$output_format" = "mp4" ]; then
        local sub_codecs
        sub_codecs=$(probe_subtitle_codecs "$input_file") || true
        local sub_index=0
        local skipped_subs=0
        while IFS= read -r codec; do
            [ -z "$codec" ] && continue
            if is_subtitle_codec_mp4_compatible "$codec"; then
                ffmpeg_args+=(-map "0:s:$sub_index")
            else
                skipped_subs=$((skipped_subs + 1))
            fi
            sub_index=$((sub_index + 1))
        done <<< "$sub_codecs"
        if [ "$skipped_subs" -gt 0 ]; then
            warn "Skipped $skipped_subs subtitle track(s) not supported in MP4 (e.g. SRT); only mov_text is copied."
        fi
    else
        ffmpeg_args+=(-map 0:s)
    fi
    ffmpeg_args+=(-c copy -f "$output_format")
    if [ "$output_format" = "mp4" ]; then
        ffmpeg_args+=(-movflags +faststart)
        num_video=$(count_video_streams "$input_file")
        local codec_lower
        codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')
        if [ "$num_video" -eq 1 ] && { [ "$codec_lower" = "hevc" ] || [ "$codec_lower" = "h265" ]; }; then
            ffmpeg_args+=(-tag:v hvc1)
        fi
    fi
    ffmpeg_args+=("$output_file")

    if ! ffmpeg "${ffmpeg_args[@]}" -loglevel info -stats -y; then
        error "Remux failed for: $input_file. Original file preserved."
        if [ -f "$output_file" ]; then
            rm -f "$output_file"
            info "Removed failed output: $output_file"
        fi
        return 1
    fi

    info "  ✓ Successfully remuxed to: $output_file"
    info "  You can pass this file to Boiler for transcoding."
    return 0
}

# Probe audio streams: output one label per line (codec + optional language/title). Order = 0-based audio index.
probe_audio_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams a -show_entries stream=codec_name:stream_tags=language,title -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # CSV: codec_name,language,title (tags may be empty)
        local codec lang title
        codec=$(echo "$line" | cut -d',' -f1)
        lang=$(echo "$line" | cut -d',' -f2)
        title=$(echo "$line" | cut -d',' -f3)
        local label="$codec"
        [ -n "$lang" ] && [ "$lang" != "N/A" ] && label="$label ($lang)"
        [ -n "$title" ] && [ "$title" != "N/A" ] && label="$label - $title"
        echo "$label"
    done <<< "$csv"
    return 0
}

# Output 0-based video stream indices that have valid dimensions (width and height > 0).
# Used for non-MP4 so we skip attached-pic streams with no dimensions (they break the muxer).
get_muxable_video_stream_indices() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    local idx=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local w h
        w=$(echo "$line" | cut -d',' -f1)
        h=$(echo "$line" | cut -d',' -f2)
        if [ -n "$w" ] && [ -n "$h" ] && [ "$w" != "N/A" ] && [ "$h" != "N/A" ] && [ "$w" -gt 0 ] 2>/dev/null && [ "$h" -gt 0 ] 2>/dev/null; then
            echo "$idx"
        fi
        idx=$((idx + 1))
    done <<< "$csv"
    return 0
}

# Probe video streams: one label per line (codec + optional title/filename). Order = 0-based video index.
probe_video_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams v -show_entries stream=codec_name:stream_tags=title,filename -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local codec title filename
        codec=$(echo "$line" | cut -d',' -f1)
        title=$(echo "$line" | cut -d',' -f2)
        filename=$(echo "$line" | cut -d',' -f3)
        local label="$codec"
        if [ -n "$title" ] && [ "$title" != "N/A" ]; then
            label="$label ($title)"
        elif [ -n "$filename" ] && [ "$filename" != "N/A" ]; then
            label="$label ($filename)"
        fi
        echo "$label"
    done <<< "$csv"
    return 0
}

# Count audio streams (ffprobe -select_streams a -show_entries stream=index -of csv)
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

main() {
    local -a positionals=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -L|--max-depth)
                if [ $# -lt 2 ]; then
                    error "--max-depth requires a value (e.g. 2 or 0 for unlimited)."
                    show_usage
                    exit 1
                fi
                local depth_val
                depth_val=$(echo "$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if ! validate_depth "$depth_val"; then
                    error "Invalid depth value: '$2'. Depth must be a non-negative integer (0 = unlimited)."
                    exit 1
                fi
                GLOBAL_MAX_DEPTH="$depth_val"
                shift 2
                ;;
            -*)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                positionals+=("$1")
                ;;
        esac
        shift
    done

    if [ ${#positionals[@]} -eq 0 ]; then
        positionals=(".")
    fi

    check_requirements

    local -a video_files=()
    while IFS= read -r path; do
        [ -n "$path" ] && video_files+=("$path")
    done < <(collect_video_files "${positionals[@]}")

    if [ ${#video_files[@]} -eq 0 ]; then
        error "No video files found in the given path(s)."
        exit 1
    fi

    local any_failed=0
    local f
    for f in "${video_files[@]}"; do
        info "--- $f ---"
        if ! process_one_file "$f"; then
            any_failed=1
            if [ ${#video_files[@]} -eq 1 ]; then
                exit 1
            fi
        fi
    done

    [ "$any_failed" -eq 1 ] && exit 1
    exit 0
}

main "$@"
