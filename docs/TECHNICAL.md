# Technical Documentation

Detailed technical documentation for the video transcoding tool's algorithms, design decisions, and implementation details.

---

## Table of Contents

1. [Quality Optimization Algorithm](#quality-optimization-algorithm)
2. [Bitrate Calculation Methods](#bitrate-calculation-methods)
3. [Multi-Pass Transcoding Strategy](#multi-pass-transcoding-strategy)
4. [Design Decisions](#design-decisions)
5. [Value Sanitization](#value-sanitization)
6. [QuickLook Compatibility](#quicklook-compatibility)

---

## Quality Optimization Algorithm

The script uses an iterative approach to find the optimal quality setting using constant quality mode (`-q:v`).

### Algorithm Steps

1. **Pre-check**: Before starting optimization, checks if source video is already within ±5% of target bitrate OR if source bitrate is below target. If either condition is true, exits early with a message indicating no transcoding is needed.

2. **Initial quality**: Starts with quality value 60 (VideoToolbox `-q:v` scale: 0-100, higher = higher quality/bitrate)

3. **Multi-point sampling**: Creates 60-second samples from multiple points in the video:
   - **Videos ≥ 180 seconds**: 3 samples at beginning (~10%), middle (~50%), and end (~90%)
   - **Videos 120-179 seconds**: 2 samples at beginning and end (with 60s spacing)
   - **Videos 60-119 seconds**: 1 sample (entire video)
   - **Videos < 60 seconds**: 1 sample (entire video, using full video duration)

4. **Bitrate measurement**: Averages bitrates from all samples using `ffprobe` or file size calculation

5. **Proportional adjustment algorithm**: Adjusts quality value proportionally based on distance from target:
   - **Minimum step**: 1 (for fine-tuning when close to target)
   - **Maximum step**: 10 (for large corrections when far from target)
   - **When bitrate too low**: Calculates ratio = actual_bitrate / target_bitrate, then adjustment = min_step + (max_step - min_step) × (1 - ratio)
     - Example: If at 50% of target (ratio=0.5), adjustment ≈ 6; if at 90% (ratio=0.9), adjustment ≈ 2
   - **When bitrate too high**: Calculates ratio = actual_bitrate / target_bitrate, then adjustment = min_step + (max_step - min_step) × (ratio - 1), capped at 1.0
     - Example: If at 200% of target (ratio=2.0), adjustment = 10; if at 110% (ratio=1.1), adjustment ≈ 2
   - Quality value bounds: 0 (lowest quality/bitrate) to 100 (highest quality/bitrate)
   - This proportional approach converges faster than fixed step sizes, making larger adjustments when far from target and smaller adjustments when close

6. **Convergence**: Stops when actual bitrate is within ±5% of target

7. **Oscillation detection**: Detects when the algorithm is cycling between quality values (e.g., 60 ↔ 61 ↔ 62) and breaks the loop by selecting the quality value that produces bitrate closest to target. Handles both 2-value oscillations and 3-value cycles.

8. **No iteration limit**: Loop continues indefinitely until convergence, oscillation detection, or quality bounds are reached

9. **Second pass transcoding**: After the full video is transcoded with the optimal quality setting, if the resulting bitrate is outside the ±5% tolerance range, automatically performs a second transcoding pass. The second pass uses `calculate_adjusted_quality()` to compute an adjusted quality value based on the actual bitrate from the first pass, using the same proportional adjustment algorithm.

10. **Third pass with linear interpolation**: If the second pass bitrate is still outside tolerance, automatically performs a third transcoding pass using `calculate_interpolated_quality()`. This function uses linear interpolation between the two known data points (first pass: quality1 → bitrate1, second pass: quality2 → bitrate2) to calculate a more accurate quality value for the target bitrate.

    This addresses overcorrection issues where the proportional adjustment algorithm overcorrects due to the non-linear relationship between quality values and bitrates in VideoToolbox encoding.

    **Interpolation formula**: `quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)`

    This ensures the final output gets as close to the target bitrate as possible, even if sample-based optimization and the second pass didn't perfectly predict the full video bitrate.

---

## Bitrate Calculation Methods

The script uses two methods to determine bitrate:

### Primary Method: ffprobe Stream Bitrate

Uses `ffprobe` to extract the stream bitrate directly from video metadata:

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_file"
```

This is the most accurate method when available.

### Fallback Method: File Size Calculation

When ffprobe cannot determine bitrate (e.g., for some container formats), calculates from file size:

```
bitrate_bps = (file_size_bytes * 8) / duration_seconds
```

This provides a reasonable approximation when metadata is unavailable.

---

## Multi-Pass Transcoding Strategy

The script implements up to three passes to achieve target bitrate accuracy:

### Pass 1: Sample-Based Optimization
- Creates multiple 60-second samples from different points in the video
- Iteratively adjusts quality value based on sample bitrates
- Uses proportional adjustment algorithm with oscillation detection
- Outputs file with optimal quality setting found

### Pass 2: Adjusted Quality (if needed)
- If Pass 1 result is outside ±5% tolerance
- Calculates new quality value using proportional adjustment: `calculate_adjusted_quality()`
- Uses same ratio-based approach as sample optimization
- Re-transcodes with adjusted quality

### Pass 3: Linear Interpolation (if needed)
- If Pass 2 result is still outside tolerance  
- Calculates quality using linear interpolation between Pass 1 and Pass 2 data points: `calculate_interpolated_quality()`
- Formula: `quality = quality2 + (quality1 - quality2) * (target - bitrate2) / (bitrate1 - bitrate2)`
- Addresses overcorrection from non-linear quality-bitrate relationship
- Final pass - no further iterations

---

## Design Decisions

### Why Constant Quality Mode (`-q:v`) Instead of Bitrate Mode?

VideoToolbox HEVC encoder supports constant quality mode via `-q:v` parameter (0-100 scale). This approach is similar to HandBrake's RF mode and CRF mode in software encoders. The iterative approach adjusts the quality value until the actual output bitrate matches the target, allowing the encoder to adapt bitrate to content complexity. This reduces blocky artifacts compared to fixed bitrate encoding.

### Why Multi-Point Sampling?

Sampling from multiple points (beginning, middle, end) provides a more accurate representation of overall video complexity. A single sample from the beginning might not represent the full video, especially if complexity varies throughout.

### Why 60-Second Samples?

Longer samples provide more accurate bitrate measurements by averaging out variation within each sample. 60 seconds balances accuracy with iteration time. For longer videos, 3 samples per iteration provide 180 seconds of total sampling, which significantly improves bitrate targeting accuracy.

### Why ±5% Tolerance?

Allows for natural variation in bitrate while still achieving the target. Too strict would require excessive iterations; too loose would miss the target.

### Why VideoToolbox Instead of libx265?

Hardware acceleration on macOS Sequoia provides significantly faster encoding while maintaining quality. VideoToolbox is optimized for Apple Silicon and Intel Macs with hardware HEVC support.

### Why No Iteration Limit?

The optimization loop continues until convergence (bitrate within ±5% tolerance), oscillation detection, or quality bounds are reached (0 or 100). This allows the algorithm to find the optimal quality setting regardless of how many iterations it takes. Quality bounds prevent infinite loops by capping the adjustment range. Oscillation detection prevents infinite cycling when tight tolerances cause the algorithm to alternate between quality values that don't quite meet the tolerance threshold.

### Why Modularize Into Functions?

The script was refactored into functions to improve:
- **Maintainability**: Each function has a single, clear responsibility
- **Readability**: The main execution flow is clear in the `main()` function
- **Testability**: Individual functions can be tested in isolation
- **Reusability**: Functions can be called independently if needed

---

## Value Sanitization

All values passed to `bc` are sanitized using `tr -d '\n\r' | xargs` to:
- Remove newlines and carriage returns that can cause `bc` parse errors
- Trim leading/trailing whitespace
- Ensure clean numeric values for calculations

This is critical because `ffprobe` and `bc` outputs may contain trailing newlines that cause parse errors when passed to subsequent `bc` calculations.

**Implementation**:
```bash
sanitize_value() {
    echo "$1" | tr -d '\n\r' | xargs
}
```

Used before all `bc` calculations to prevent parse errors from unexpected whitespace.

---

## QuickLook Compatibility

The script includes flags to ensure macOS Finder QuickLook compatibility:

### `-movflags +faststart`
Moves metadata (moov atom) to the beginning of the file, allowing QuickLook to read file information immediately without scanning the entire file. Applied to both sample transcoding and final output.

### `-tag:v hvc1`
Ensures proper HEVC codec tagging in the MP4 container for better compatibility with macOS QuickTime/QuickLook. Applied only to the final transcoded output (not to temporary sample files).

### Usage Differences

- **Sample files**: Use `-movflags +faststart` for faster bitrate measurement
- **Final output**: Includes both flags for full QuickLook compatibility

This ensures transcoded videos work seamlessly with macOS Finder's QuickLook feature.
