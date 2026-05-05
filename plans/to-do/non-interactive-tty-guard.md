# Plan: Non-Interactive / TTY Guard for Interactive Prompts

## Problem

Scripts with user-facing `read` prompts (`remux-select-audio.sh`, and soon `remux-only.sh`)
have no guard against being run non-interactively (piped, scripted, CI). If stdin is not a
TTY, `read` returns immediately with empty input, and empty input may silently trigger an
unintended default behavior rather than clearly failing.

`boiler.sh` has no interactive prompts and is unaffected.

## Affected Scripts

- `remux-select-audio.sh` — prompts for audio track selection; empty = keep all (currently safe but silent)
- `remux-only.sh` — will gain subtitle confirmation prompts (see subtitle-detection-remux.md)

## Goal

Decide on and implement a consistent approach across all interactive scripts so that
non-interactive invocation produces predictable, clearly-communicated behavior.

---

## Options to Evaluate

### Option A: Explicit TTY guard per prompt
Check `[ -t 0 ]` before each interactive prompt. If not a TTY, skip the file with a warning.
- Pro: explicit, visible failure
- Con: new pattern not present elsewhere; verbose

### Option B: Default behavior on empty input (current approach)
`read -r var || true` — empty input falls through to whatever the defined default is.
- Pro: consistent with existing code
- Con: silent; caller may not realize the script ran non-interactively

### Option C: Add `--non-interactive` / `--yes` flags
CLI flags to pre-confirm or skip interactive decisions. Scripts remain usable in automation.
- Pro: ergonomic for scripting
- Con: scope and API design work; each script needs its own flag handling

### Option D: Shared guard function
A single `require_tty()` helper sourced by all scripts — checks `[ -t 0 ]`, exits with a
clear message if not a TTY.
- Pro: consistent across scripts, one place to change
- Con: introduces a shared-library pattern not currently in the codebase

---

## Items (stubbed — to be detailed when this plan is activated)

- [ ] Decide on approach (A, B, C, D, or hybrid)
- [ ] Apply consistently to `remux-select-audio.sh`
- [ ] Apply consistently to `remux-only.sh`
- [ ] Update tests if behavior changes
- [ ] Update README/docs if user-facing behavior changes

---

## Out of Scope

- `boiler.sh` (no interactive prompts)
- `cleanup-originals.sh`, `remux-only.sh` non-prompt logic
