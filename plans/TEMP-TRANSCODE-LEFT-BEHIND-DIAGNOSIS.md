# Diagnosis: temp_transcode left behind, final file missing (pinned)

**Pinned for reference.** See possible fixes at end; implement when ready.

## What you're seeing

- A `*_temp_transcode.*` file is still on disk.
- The log showed the run "settling" (e.g. second/third pass within tolerance or "using this result").
- The final transcoded file (e.g. `{base}.fmpg.{bitrate}.Mbps.mp4`) is missing.

**Sharpening observation:** The temp file that's left behind has the same properties as the expected result file would—same file size, bitrate, etc. It is the full, correct transcoded output; it's just still named like a temporary file instead of the final `.fmpg.*.Mbps.mp4` name.

So transcoding completed successfully. The only step that did not succeed is the **rename** from temp name to final name. That rules out partial writes, corrupt output, or the wrong file; the failure is specifically that `mv "$temp_output_file" "$OUTPUT_FILE"` either never ran or failed.

## Root cause

Two mechanisms can produce this; both leave the temp file behind because **the exit handler never deletes it**. In both cases the **transcode and multi-pass logic finished**; only the **final rename** did not.

### 1. Interrupt or exit after the last pass, before/during the final rename

If the process exits after the "settled" messages but before or during the `mv` (e.g. Ctrl+C, SIGTERM), the final `mv` never runs or doesn't complete. `cleanup_on_exit` only removes sample files, not `*_temp_transcode.*`.

### 2. `mv` fails and the script exits (set -e)

The script does not check the result of `mv`. If `mv` fails (permission, read-only FS, disk full, etc.), the script exits immediately. In an uninterrupted batch run, this is the likely explanation when the temp is complete and correct: the rename failed for some reason.

## Why the temp file is never cleaned up

- On **success**, the temp is removed by renaming it to `OUTPUT_FILE`.
- On **error** inside the multi-pass block, the script explicitly `rm -f "$temp_output_file"` in several branches.
- On **exit** (trap), `cleanup_on_exit` only kills the process group and removes sample files; it does **not** remove the temp transcode file.

## Possible fixes (for later implementation)

- **Cleanup in trap**: In `cleanup_on_exit`, also remove the current temp transcode file (e.g. pattern `"${VIDEO_FILE%.*}_temp_transcode."*`).
- **Check `mv`**: Run `mv` in an `if ! mv ...; then rm -f "$temp_output_file"; return 1; fi` so that on rename failure the script cleans up and exits with a clear error.
