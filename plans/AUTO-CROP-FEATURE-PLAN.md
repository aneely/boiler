# Auto-Crop Feature Plan: Detect and Remove Baked-in Letterboxing

## Objective

Add automatic detection and removal of baked-in letterboxing/pillarboxing during transcoding. FFmpeg's `cropdetect` filter will identify solid-color borders, and the tool will automatically crop them out to reduce file size and improve viewing experience.

**Status**: Planned | **Priority**: High | **Effort**: Medium

**Implementation Strategy**: This feature will initially be exposed as standalone subcommands to allow testing and validation of the detection algorithms. Integration into the automatic batch workflow is a future enhancement that will be decided after the subcommand infrastructure is in place.

## Requirements

### User Requirements
1. **Opt-in feature**: Must be explicitly enabled with `--auto-crop` flag
2. **Conservative approach**: Only crop when significant letterboxing is detected (>5% of frame)
3. **Accuracy**: Sample multiple points to ensure consistent detection
4. **Safety**: Skip cropping if burned-in subtitles are detected in black bar areas
5. **Transparency**: Log detected crop region and show before/after dimensions

### Technical Requirements
1. Detection accuracy across different video positions (beginning, middle, end)
2. Consistency validation across samples
3. False positive prevention (dark scenes vs. actual letterboxing)
4. Integration with existing transcoding pipeline
5. Works with sample-based bitrate prediction (must apply crop to samples too)

## Proposed Solution

### Architecture Strategy

#### Phase 1: Subcommand Exposure (Immediate)

Standalone commands for testing and validation:

```
┌─────────────────────────────────────────────────────────┐
│              Standalone Detection Commands                 │
├─────────────────────────────────────────────────────────┤
│  boiler detect-crop <file>                               │
│     ├─ detect_black_bars()                              │
│     ├─ check_subtitles_in_crop_zone()                    │
│     └─ Output: crop params or "no cropping needed"        │
│                                                          │
│  boiler preview-crop <file>                              │
│     ├─ Run detection                                     │
│     ├─ Show before/after dimensions                     │
│     └─ Visual confirmation (ASCII art or log)           │
└─────────────────────────────────────────────────────────┘
```

**Benefits:**
- Test detection algorithms without touching transcoding logic
- Validate on diverse video content before batch integration
- Users can preview what would be cropped before committing
- Debugging and threshold tuning without re-transcoding

#### Phase 2: Optional Batch Integration (Future Decision)

Open decisions to be resolved after Phase 1:

| Decision | Options | Status |
|----------|---------|--------|
| **Flag name** | `--auto-crop`, `--crop`, other? | Undecided |
| **Default behavior** | Opt-in vs opt-out | Undecided |
| **Integration point** | Before sample transcode vs global preprocessing | Undecided |
| **Per-file override** | Skip crop for specific files | Undecided |
| **Global vs local** | `--auto-crop` as global flag vs per-file decision | Undecided |

**Candidate integration points:**

Option A: Global preprocessing pass
```bash
boiler batch --auto-crop
# Detects crop for all files first, then transcodes
```

Option B: Per-file during transcoding
```bash
boiler transcode --auto-crop <file>
# Detects and applies crop as part of single-file workflow
```

Option C: Both (user's choice)
- Global for batch convenience
- Per-file for granular control

Option D: Never automatic (subcommands only)
- Keep it as manual tools only
- Users must explicitly request crop per-file

**Note:** These decisions depend on:
1. Accuracy of detection algorithms (Phase 1 validation)
2. Performance impact measurements
3. User feedback on subcommand usability
4. Subcommand infrastructure implementation

### New Functions

#### `detect_black_bars(video_file)`
**Purpose**: Detect black bar letterboxing using FFmpeg cropdetect

**Implementation Details**:
```bash
# Sample strategy: beginning (10%), middle (50%), end (90%)
# Frame count: 50-100 frames per sample for accuracy
# Parse output: crop=W:H:X:Y format

ffmpeg -ss <timestamp> -i "<video>" -vframes 100 \
    -vf "cropdetect=limit=24:round=2:reset=0" -f null - 2>&1
```

**Parameters to Tune**:
- `limit`: Black threshold (0-255, default 24). Higher = more aggressive detection
- `round`: Round to multiple of N pixels (default 2 for even dimensions)
- `reset`: Counter for periodically resetting detection (0 = never reset)

**Validation Logic**:
1. Run cropdetect at 3 sample points (10%, 50%, 90% of duration)
2. Parse crop values from stderr output
3. Check consistency: all samples must agree within ±2 pixels
4. Calculate percentage of frame being removed
5. If <5% of frame would be removed, return empty (false positive protection)
6. Check for burned subtitles (see below)

**Returns**: `crop=W:H:X:Y` string or empty string if no cropping needed

#### `check_subtitles_in_crop_zone(video_file, crop_params)`
**Purpose**: Detect if burned-in subtitles exist in the area that would be cropped

**Implementation Approach**:
Option A: OCR-based detection (heavy, requires tesseract)
Option B: Scene change analysis in crop zone (lighter)
Option C: Pixel variance analysis (simplest)

**Recommended**: Option C - Pixel variance analysis
- Extract frames in the crop zone (top/bottom strips)
- Calculate pixel variance across time
- High variance = potential text/subtitles
- If variance > threshold in crop zone, reject cropping

**Returns**: 0 if safe to crop, 1 if subtitles detected

#### `parse_cropdetect_output(ffmpeg_stderr)`
**Purpose**: Parse cropdetect filter output to extract W:H:X:Y values

**Example Input**:
```
[Parsed_cropdetect_0 @ 0x7f8c0f504140] x1:0 x2:1919 y1:140 y2:939 w:1920 h:800 x:0 y:140 pos:...
```

**Returns**: Parsed crop string `1920:800:0:140`

### Modified Functions

#### `transcode_sample()`
**Change**: Add crop filter if crop_params is provided
```bash
local crop_filter=""
if [ -n "$crop_params" ]; then
    crop_filter="crop=$crop_params,"
fi

ffmpeg -i "$video_file" -vf "${crop_filter}scale=..." ...
```

#### `transcode_full_video()`
**Change**: Add crop filter to video filter chain
```bash
ffmpeg -i "$video_file" \
    -c:v hevc_videotoolbox \
    -q:v ${quality_value} \
    -vf "crop=$crop_params" \  # Added when crop detected
    -c:a copy \
    ...
```

#### `parse_arguments()`
**Change**: Add `--auto-crop` flag handling
```bash
--auto-crop)
    AUTO_CROP=1
    shift
    ;;
```

### Global Variables

```bash
AUTO_CROP=0              # Flag: auto-crop enabled
CROP_PARAMS=""           # Detected crop parameters (W:H:X:Y)
CROP_CONSISTENT=0        # Whether crop was consistent across samples
```

## Implementation Phases

### Phase 1: Detection Algorithm (Standalone)
- [ ] Implement `detect_black_bars()` with multi-point sampling
- [ ] Implement `parse_cropdetect_output()` helper  
- [ ] Implement `check_subtitles_in_crop_zone()` using pixel variance
- [ ] Add logging for detected crop regions
- [ ] Test with sample videos to determine optimal thresholds

**Deliverable:** Working detection functions callable independently

### Phase 2: Subcommand Interface
- [ ] Implement `boiler detect-crop <file>` subcommand
- [ ] Implement `boiler preview-crop <file>` subcommand
- [ ] Add output formatting (txt, json options)
- [ ] Add bats tests for subcommands
- [ ] Document subcommand usage

**Deliverable:** Users can detect and preview crops without transcoding

### Phase 3: Transcoding Integration (Optional)
**Prerequisites:** Subcommand infrastructure complete, detection accuracy validated

- [ ] Decide on `--auto-crop` flag placement (global vs subcommand)
- [ ] Modify `transcode_sample()` to apply crop (if crop_params provided)
- [ ] Modify `transcode_full_video()` to apply crop filter
- [ ] Update bitrate calculations to account for cropped dimensions
- [ ] Ensure multi-pass transcoding works correctly with crop

**Note:** This phase is contingent on Phase 1 & 2 validation. If detection accuracy is insufficient, we may keep this as subcommands-only indefinitely.

### Phase 4: Batch Integration (Optional)
**Prerequisites:** Phase 3 complete and stable

- [ ] Evaluate if automatic batch cropping is desirable
- [ ] Decide on global flag vs per-file opt-in
- [ ] Implement chosen integration pattern
- [ ] Add comprehensive integration tests

### Phase 5: Documentation
- [ ] Update README.md with subcommand documentation
- [ ] Document `--auto-crop` if implemented
- [ ] Add usage examples and decision guidance
- [ ] Update PLAN.md to reflect final architecture

## Open Questions to Resolve

### 1. Detection Threshold
**Question**: What percentage of the frame must be black bars to trigger cropping?

**Test Plan**:
- Create/gather test videos with varying letterboxing:
  - 2% black bars (minimal, likely false positive)
  - 5% black bars (questionable)
  - 10% black bars (clear letterboxing)
  - 25% black bars (heavy cinematic)
- Test cropdetect sensitivity at each level
- Determine threshold that minimizes false positives

**Decision Needed**: Exact percentage threshold (default: 5%)

### 2. Pixel Variance Threshold for Subtitles
**Question**: What variance level indicates potential subtitles vs. static black bars?

**Test Plan**:
- Sample videos with:
  - Clean letterboxing (uniform black)
  - Subtitles in black bar area
  - Scene changes in active video area only
- Measure pixel variance in crop zones
- Establish threshold that catches subtitles without false positives

**Decision Needed**: Variance threshold value

### 3. Crop Consistency Tolerance
**Question**: How much variation across samples is acceptable?

**Options**:
- Strict: All samples must match exactly
- Lenient: ±2 pixel tolerance
- Adaptive: Allow more tolerance for longer videos

**Decision Needed**: Tolerance value (recommendation: ±2 pixels)

### 4. Performance Impact
**Question**: How much time does crop detection add per file?

**Estimate**:
- 3 sample points × 100 frames each
- ~300 frames to decode and analyze
- Depends on video resolution and duration
- Estimated: 2-5 seconds per file

**Decision**: Acceptable for opt-in feature

### 5. Crop Efficiency vs Remuxing
**Question**: Is cropping without transcoding as fast and efficient as remuxing, or is it more practical to transcode and crop in the same operation?

**Context:**
- Remuxing copies streams without re-encoding (very fast)
- Cropping requires re-encoding because frame dimensions change
- For incompatible codecs, we already need to transcode - adding crop is "free"
- For compatible codecs, crop forces a transcode when remux would suffice

**Options to Evaluate:**

**Option A: Remux-then-detect (preview only)**
- Remux incompatible formats to MP4 first (copy streams)
- Detect crop on remuxed file
- User decides whether to re-transcode with crop or keep remuxed
- Pros: Fast remux, user control over whether to transcode
- Cons: Two-step process, requires manual decision

**Option B: Detect-then-decide**
- Run crop detection on source file first
- If crop detected AND codec compatible: suggest transcoding with crop
- If crop detected AND codec incompatible: transcoding happens anyway, include crop
- Pros: Informed decision before committing to transcode
- Cons: Detection takes time even if user decides not to crop

**Option C: Always transcode when cropping**
- If user requests crop, always do full transcode (no remux option)
- Simple but potentially wasteful for already-optimized files

**Option D: Separate crop subcommand only**
- Never integrate into automatic flow
- Users must explicitly run `boiler transcode --crop` after detection
- Most conservative approach

**Test Plan:**
- Measure time for: crop detection + remux vs transcode with crop
- Compare file sizes: remuxed vs cropped-transcoded
- Test with various video types (h264, hevc, incompatible)
- Gather user preference data on workflow

**Decision Needed:** Whether cropping should ever be automatic, or always require explicit transcoding decision

## Testing Strategy

### Unit Tests
- [ ] `detect_black_bars()` returns correct crop string
- [ ] `detect_black_bars()` handles inconsistent crops
- [ ] `parse_cropdetect_output()` correctly parses various formats
- [ ] `check_subtitles_in_crop_zone()` detects subtitles
- [ ] Integration with `--auto-crop` flag

### Integration Tests
- [ ] Full transcoding with crop detection
- [ ] Bitrate prediction accuracy with cropping
- [ ] Multi-pass transcoding with crop
- [ ] Sample transcoding with crop

### Manual Test Videos Needed
- [ ] 1920x1080 container with 1920x800 content (cinematic)
- [ ] 1920x1080 container with 1440x1080 content (4:3 pillarbox)
- [ ] 3840x2160 container with 3840x1600 content (4K cinematic)
- [ ] Video with subtitles in black bar area
- [ ] Dark movie scenes (false positive test)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| False positives crop actual content | High | >5% threshold, multi-point validation |
| Subtitle detection misses burned subs | Medium | Pixel variance with conservative threshold |
| Performance overhead | Low | Opt-in feature, async detection possible |
| Bitrate prediction less accurate | Medium | Apply crop to samples too |
| Aspect ratio distortion | Low | Use exact cropdetect values, no rounding to standards |
| Subcommand infrastructure dependency | High | Implement detection functions first, UI after subcommand architecture ready |

## Success Criteria

- [ ] Feature works with `--auto-crop` flag
- [ ] Correctly detects and crops letterboxing in test videos
- [ ] Skips cropping when subtitles detected
- [ ] No false positives on dark scenes
- [ ] Bitrate prediction remains accurate
- [ ] All tests pass (legacy + bats)
- [ ] Documentation updated

## Future Enhancements (Out of Scope)

- Interactive mode showing crop preview
- Automatic aspect ratio standardization (user preference)
- AI-based content detection (more accurate than pixel variance)
- Crop parameter caching for re-processing
- Batch detection across all files before transcoding

## References

- [FFmpeg cropdetect filter documentation](https://ffmpeg.org/ffmpeg-filters.html#cropdetect)
- [Stack Overflow: Auto-crop black bars](https://stackoverflow.com/questions/61084983/how-to-automatically-remove-black-bars-using-ffmpeg)
- [Super User: Is it possible to autocrop black borders](https://superuser.com/questions/772795/is-it-possible-to-autocrop-black-borders-of-a-video-with-ffmpeg)
