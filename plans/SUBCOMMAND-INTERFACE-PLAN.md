# Subcommand Interface Plan: CLI Subcommands for Individual Operations

## Objective

Expose the modular function architecture of `boiler.sh` as individual CLI subcommands, enabling users to run specific operations (discovery, analysis, remuxing, transcoding) against particular files or file lists without going through the full batch processing workflow.

**Status**: Planned | **Priority**: Medium | **Effort**: Medium

## Requirements

### User Requirements
1. **Granular control**: Run individual operations without full batch processing
2. **Scripting support**: Exit codes and parseable output for automation
3. **Backward compatibility**: Default `boiler` behavior remains batch processing
4. **Discoverability**: Clear command structure matching the internal architecture
5. **Consistency**: Same flags/behavior across subcommands where applicable

### Technical Requirements
1. Command dispatcher to route to appropriate functions
2. Global variables must be passable to subcommand contexts
3. Signal handling must work correctly in subcommand mode
4. Functions need to work independently without relying on batch state
5. Maintain existing test coverage and add tests for new interface

## Proposed Solution

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Command Dispatch                        │
├─────────────────────────────────────────────────────────┤
│  boiler [GLOBAL_OPTIONS] <SUBCOMMAND> [ARGS...]          │
│                                                          │
│  Global Options:                                         │
│    -t, --target-bitrate RATE  Override target bitrate   │
│    -L, --max-depth DEPTH      Search depth limit        │
│    -h, --help                 Show help                 │
│                                                          │
│  Subcommands:                                            │
│    discover [OPTIONS]       List files for processing   │
│    analyze <file>           Show file properties        │
│    target <file>            Show target bitrate         │
│    should-skip <file>       Check if file would be skipped│
│    remux <file>             Remux to MP4 container       │
│    optimize-quality <file>  Dry-run quality search       │
│    transcode <file>         Single file transcoding      │
│    batch [OPTIONS]          Batch process (default)      │
└─────────────────────────────────────────────────────────┘
```

### Global Flag Applicability by Subcommand

**Global options** (`-t`, `-L`) apply selectively based on subcommand purpose:

| Global Flag | `-h, --help` | `-t, --target-bitrate` | `-L, --max-depth` |
|-------------|-------------|------------------------|-------------------|
| `discover` | ✓ | ✗ | ✓ |
| `analyze` | ✓ | ✗ | ✗ |
| `target` | ✓ | ✓ | ✗ |
| `should-skip` | ✓ | ✗ | ✗ |
| `remux` | ✓ | ✓ | ✗ |
| `optimize-quality` | ✓ | ✓ | ✗ |
| `transcode` | ✓ | ✓ | ✗ |
| `batch` | ✓ | ✓ | ✓ |

**Rationale**:
- `-L` only affects file discovery (used by `discover` and `batch`)
- `-t` affects any operation involving target bitrate calculation or transcoding
- Single-file operations (`analyze`, `target`, `should-skip`, `remux`, `optimize-quality`, `transcode`) don't need `-L` since they take explicit file paths

### Subcommand Specifications

#### `boiler discover [OPTIONS]`
**Purpose**: List files that would be processed in batch mode

**Options**:
- `-s, --skipped`: List files being skipped instead of processed
- `--format=txt|json`: Output format (default: txt, one file per line) - no short flag
- `-L, --max-depth DEPTH`: Maximum directory depth (inherits global)

**Maps to**: `find_all_video_files()` / `find_skipped_video_files()`

**Output**:
```
$ boiler discover
video1.mp4
subfolder/video2.mkv
video3.mov

$ boiler discover --skipped
video1.fmpg.8.2.Mbps.mp4  # already encoded
video2.orig.5.1.Mbps.mp4  # below target
```

**Exit codes**:
- 0: Success (files found)
- 1: No files found
- 130: Interrupted

---

#### `boiler analyze <file>`
**Purpose**: Show comprehensive file properties

**Options**:
- `-j, --json`: Output in JSON format

**Maps to**: `get_video_resolution()`, `get_video_duration()`, `get_source_bitrate()`, `get_video_codec()`

**Output**:
```
$ boiler analyze video.mkv
File: video.mkv
Resolution: 1920x1080 (1080p)
Duration: 3600s (1:00:00)
Codec: h264
Source Bitrate: 12.5 Mbps
Target Bitrate: 8.0 Mbps (1080p tier)
Format: MKV (non-QuickLook compatible)

$ boiler analyze --json video.mkv
{
  "file": "video.mkv",
  "resolution": "1920x1080",
  "height": 1080,
  "duration_seconds": 3600,
  "codec": "h264",
  "source_bitrate_mbps": 12.5,
  "target_bitrate_mbps": 8.0,
  "format_quicklook_compatible": false
}
```

**Exit codes**:
- 0: Success
- 1: File not found or unreadable
- 2: Analysis failed (ffprobe error)

---

#### `boiler target <file>`
**Purpose**: Show target bitrate for a file based on its resolution

**Options**:
- `-t, --target-bitrate RATE`: Override target bitrate for calculation
- `-v, --verbose`: Show detailed tier information

**Maps to**: `get_video_resolution()` + `calculate_target_bitrate()`

**Output**:
```
$ boiler target video.mp4
Target: 8.0 Mbps (1080p)

$ boiler target --verbose video.mp4
Resolution: 1920x1080
Target Bitrate: 8.0 Mbps
Bitrate Tiers:
  - 2160p: 11.0 Mbps
  - 1080p: 8.0 Mbps  <- current
  - 720p: 5.0 Mbps
  - 480p: 2.5 Mbps
Acceptable Range: 7.6 - 8.4 Mbps (±5%)
```

**Exit codes**:
- 0: Success
- 1: Cannot determine resolution

---

#### `boiler should-skip <file>`
**Purpose**: Check if file would be skipped (scripting-friendly)

**Options**:
- `-r, --reason`: Show skip reason (why file would be skipped)

**Maps to**: `should_skip_file()` + `has_encoded_version()`

**Output**:
```
$ boiler should-skip video.mp4 && echo "Would process" || echo "Would skip"
Would process

$ boiler should-skip video.fmpg.8.0.Mbps.mp4 && echo "Would process" || echo "Would skip"
Would skip

$ boiler should-skip --reason video.fmpg.8.0.Mbps.mp4
SKIP: Already encoded (.fmpg. marker)
Exit code: 1 (would skip)
```

**Exit codes**:
- 0: Would process this file
- 1: Would skip this file
- 2: File not found

---

#### `boiler remux <file>`
**Purpose**: Remux video to MP4 container (no transcoding)

**Options**:
- `-f, --force`: Overwrite existing output
- `-o, --output <path>`: Custom output path (default: `{base}.mp4`)
- `-t, --target-bitrate RATE`: When transcoding incompatible codecs, use this bitrate (inherits global)

**Output**:
```
$ boiler remux video.mkv
[INFO] Remuxing video.mkv to video.mp4...
[INFO] Remux complete: video.mp4

$ boiler remux incompatible.wmv
[WARN] Codec WMV3 is not MP4-compatible, transcoding required
[INFO] Transcoding at source bitrate for QuickLook compatibility...
[INFO] Transcode complete: incompatible.orig.5.2.Mbps.mp4
```

**Exit codes**:
- 0: Success (remuxed or transcoded)
- 1: Failed
- 2: Output file already exists (without --force)

---

#### `boiler optimize-quality <file>`
**Purpose**: Dry-run quality optimization to preview settings

**Options**:
- `-t, --target-bitrate RATE`: Override target bitrate for optimization (inherits global)

**Output**:
```
$ boiler optimize-quality video.mp4
[INFO] Analyzing video.mp4...
[INFO] Duration: 3600s
[INFO] Target Bitrate: 8.0 Mbps
[INFO] 
[INFO] Sample-based optimization (dry run):
[INFO]   Sample 1 (10%): quality 58 → 7.2 Mbps
[INFO]   Sample 2 (50%): quality 58 → 7.8 Mbps
[INFO]   Sample 3 (90%): quality 58 → 8.1 Mbps
[INFO] 
[INFO] Optimal quality setting: 58
[INFO] Predicted bitrate: ~7.7 Mbps (within ±5% tolerance)
[INFO] 
[INFO] Note: This was a dry run. Use 'boiler transcode' to actually encode.
```

**Exit codes**:
- 0: Success, quality found
- 1: Analysis failed
- 2: Could not converge on quality

---

#### `boiler transcode <file>`
**Purpose**: Transcode a single file

**Options**:
- `-t, --target-bitrate RATE`: Override target bitrate (inherits global)
- `-q, --quality N`: Skip optimization, use specific quality (0-100)
- `-n, --dry-run`: Show what would be done without encoding (no-act mode)

**Output**:
```
$ boiler transcode video.mp4
[INFO] Processing: video.mp4
[INFO] Resolution: 1080p
[INFO] Target bitrate: 8.0 Mbps
[INFO] 
[INFO] Finding optimal quality...
[INFO] Optimal quality: 58
[INFO] 
[INFO] Transcoding...
[INFO] Pass 1 complete: 7.9 Mbps
[INFO] 
[INFO] Transcoding complete!
[INFO] Output: video.fmpg.7.9.Mbps.mp4

$ boiler transcode video.mp4 --quality 60
[INFO] Using specified quality: 60 (skipping optimization)
[INFO] Transcoding...
...
```

**Exit codes**:
- 0: Success
- 1: Failed
- 130: Interrupted

---

#### `boiler batch [OPTIONS]`
**Purpose**: Batch process all files (current default behavior, made explicit)

**Options**:
- `-t, --target-bitrate RATE`: Override target bitrate for all files (inherits global)
- `-L, --max-depth DEPTH`: Maximum directory depth to traverse (inherits global)

**Maps to**: `main()` (current behavior)

**Options**: Same as current global options

**Note**: This makes the batch mode explicit. Running `boiler` without a subcommand could still default to batch mode for backward compatibility.

**Output**: Same as current batch output

**Exit codes**:
- 0: All files processed
- 1: Some files failed or no files found
- 130: Interrupted

### Modified Functions

#### `main()` - Command Dispatch Restructure
**Current**: `main()` handles argument parsing then runs batch processing

**Proposed**: Split into dispatcher + implementations:

```bash
# New dispatcher pattern
dispatch_command() {
    local subcommand="$1"
    shift
    
    case "$subcommand" in
        discover)
            run_discover "$@"
            ;;
        analyze)
            run_analyze "$@"
            ;;
        target)
            run_target "$@"
            ;;
        should-skip)
            run_should_skip "$@"
            ;;
        remux)
            run_remux "$@"
            ;;
        optimize-quality)
            run_optimize_quality "$@"
            ;;
        transcode)
            run_transcode "$@"
            ;;
        batch|"")
            # Empty subcommand defaults to batch for backward compatibility
            run_batch "$@"
            ;;
        --help|-h)
            show_help
            ;;
        *)
            error "Unknown subcommand: $subcommand"
            show_help
            exit 1
            ;;
    esac
}

# Example implementation
run_discover() {
    local show_skipped=0
    local format="txt"
    
    # Parse subcommand-specific arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skipped)
                show_skipped=1
                shift
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Run discovery
    if [ "$show_skipped" -eq 1 ]; then
        find_skipped_video_files | sort
    else
        find_all_video_files | sort
    fi
}

run_analyze() {
    local video_file="$1"
    local format="txt"
    
    # Extract properties
    local resolution duration codec bitrate
    resolution=$(get_video_resolution "$video_file")
    duration=$(get_video_duration "$video_file")
    codec=$(get_video_codec "$video_file")
    bitrate=$(get_source_bitrate "$video_file" "$duration")
    
    # Output based on format
    if [ "$format" = "json" ]; then
        printf '{"file":"%s","resolution":"%s",...}\n' "$video_file" ...
    else
        echo "File: $video_file"
        echo "Resolution: $resolution"
        # ... etc
    fi
}
```

#### `parse_arguments()` - Global vs Subcommand Args
**Change**: Split into two phases:
1. Parse global options (before subcommand)
2. Pass remaining args to subcommand handler

```bash
parse_global_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-bitrate|-t)
                GLOBAL_TARGET_BITRATE_MBPS="$2"
                shift 2
                ;;
            --max-depth|-L)
                GLOBAL_MAX_DEPTH="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --)  # End of global args
                shift
                break
                ;;
            -*)
                # Unknown global option - might be subcommand arg, pass through
                break
                ;;
            *)
                # First non-option is subcommand
                break
                ;;
        esac
    done
    
    # Remaining args are for subcommand
    echo "$@"  # Return remaining args
}
```

### Global Variable Handling

**Problem**: Functions currently rely on globals like `GLOBAL_TARGET_BITRATE_MBPS`, `GLOBAL_MAX_DEPTH`, `INTERRUPTED`

**Solutions**:

1. **Environment Variables**: Pass via environment
   ```bash
   BOILER_TARGET_BITRATE=9.5 boiler transcode video.mp4
   ```

2. **Explicit Arguments**: Modify functions to accept parameters
   ```bash
   transcode_video "$file" "$target" "$depth"
   ```

3. **Hybrid Approach**: Keep globals but allow override via env vars
   ```bash
   run_transcode() {
       local target="${BOILER_TARGET_BITRATE:-$GLOBAL_TARGET_BITRATE_MBPS}"
       transcode_video "$1" "$target"
   }
   ```

**Recommended**: Option 3 (hybrid) for minimal code change while enabling subcommand flexibility

### Signal Handling Considerations

**Problem**: Current signal handlers use `VIDEO_FILE` global for cleanup

**Solution**: Subcommands that don't set `VIDEO_FILE` should disable signal-based cleanup or use different handlers:

```bash
run_discover() {
    # Discovery doesn't create files, no cleanup needed
    # Disable interrupt handling or use simpler handler
    trap '' INT  # Ignore interrupts for simple listing
    find_all_video_files
}

run_transcode() {
    # Full transcoding needs proper cleanup
    local VIDEO_FILE="$1"
    trap 'cleanup_on_interrupt' INT
    transcode_video "$VIDEO_FILE"
}
```

## Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Refactor `parse_arguments()` to support global + subcommand args
- [ ] Create `dispatch_command()` router
- [ ] Implement `run_batch()` (extract current `main()` behavior)
- [ ] Ensure backward compatibility: `boiler` without subcommand still works
- [ ] Tests: All existing tests still pass

### Phase 2: Discovery Subcommands
- [ ] Implement `run_discover()` with `--skipped` option
- [ ] Add formatted output (txt default, json option)
- [ ] Tests: bats tests for discover subcommand
- [ ] Documentation: Update README with discover usage

### Phase 3: Analysis Subcommands
- [ ] Implement `run_analyze()` with txt and json output
- [ ] Implement `run_target()` with verbose mode
- [ ] Implement `run_should_skip()` with proper exit codes
- [ ] Tests: bats tests for analyze, target, should-skip

### Phase 4: Operation Subcommands
- [ ] Implement `run_remux()` with `--force` and `--output` options
- [ ] Implement `run_optimize_quality()` dry-run mode
- [ ] Implement `run_transcode()` with `--quality` override
- [ ] Tests: bats tests for remux, optimize-quality, transcode

### Phase 5: Documentation & Polish
- [ ] Update README.md with comprehensive subcommand documentation
- [ ] Create examples for scripting use cases
- [ ] Update PLAN.md to mark feature as implemented
- [ ] Update PROJECT-CONTEXT.md with new architecture notes
- [ ] Update docs/ARCHITECTURE.md to reference the plan (or remove duplication)

## Open Questions to Resolve

### 1. Default Behavior
**Question**: Should `boiler` without any subcommand still default to batch mode?

**Options**:
- A: Yes, maintain full backward compatibility
- B: No, show help message listing subcommands
- C: Yes, but show deprecation warning suggesting `boiler batch`

**Recommendation**: Option A for minimal disruption

### 2. Output Format Strategy
**Question**: Which subcommands need structured output (JSON)?

**Options**:
- A: All subcommands support --format=json
- B: Only data-heavy commands (analyze, discover)
- C: Only when explicitly requested per-command

**Recommendation**: Option B initially, add to others as needed

### 3. Global Option Position
**Question**: Should global options come before or after subcommand?

**Options**:
- A: `boiler --target-bitrate 9.5 transcode video.mp4` (before)
- B: `boiler transcode video.mp4 --target-bitrate 9.5` (after)
- C: Support both

**Recommendation**: Option A (standard CLI pattern like `docker run --rm image`)

### 4. Exit Code Standardization
**Question**: What exit codes should we standardize across subcommands?

**Proposed**:
- 0: Success
- 1: General failure / file not found
- 2: Validation error (bad args, unsupported format)
- 130: Interrupted by user (SIGINT)
- 3+: Subcommand-specific (optional)

## Testing Strategy

### Unit Tests
- [ ] `dispatch_command()` routes correctly
- [ ] `run_discover()` returns correct file lists
- [ ] `run_analyze()` outputs correct properties
- [ ] `run_should_skip()` returns correct exit codes
- [ ] Global option parsing works with all subcommands

### Integration Tests
- [ ] End-to-end: `boiler discover` finds expected files
- [ ] End-to-end: `boiler analyze` shows correct properties
- [ ] End-to-end: `boiler transcode` produces correct output
- [ ] Backward compatibility: `boiler` alone still batch processes
- [ ] Global options affect subcommands correctly

### Regression Tests
- [ ] All existing tests pass without modification
- [ ] `boiler` (no args) still works as before
- [ ] `boiler --target-bitrate 9.5` still works as before

## Success Criteria

- [ ] All proposed subcommands implemented
- [ ] Backward compatibility maintained
- [ ] Exit codes follow standardization proposal
- [ ] Tests pass (legacy + bats + new subcommand tests)
- [ ] Documentation updated (README, PLAN, ARCHITECTURE)
- [ ] Scripting use cases work (exit codes, parseable output)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking backward compatibility | High | Default to batch mode, extensive testing |
| Increased complexity | Medium | Clean separation between dispatcher and implementations |
| Global variable bugs | Medium | Careful testing of subcommand-specific handlers |
| Exit code conflicts | Low | Standardize exit codes, document them |

## References

- [GNU Program Argument Syntax Conventions](https://www.gnu.org/software/libc/manual/html_node/Argument-Syntax.html)
- [POSIX Exit Codes](https://www.gnu.org/software/libc/manual/html_node/Exit-Status.html)
- See `docs/ARCHITECTURE.md` for function mappings and decomposition details
