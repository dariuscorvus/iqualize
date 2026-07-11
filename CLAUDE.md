# iQualize

macOS menu bar audio equalizer using system audio capture + AVAudioEngine.

## Version Bumping

Version lives in `Sources/iQualize/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`).

**When to bump:**
- **Patch** (0.3.0 → 0.3.1): bug fixes only
- **Minor** (0.3.0 → 0.4.0): new features or UI changes
- **Major** (0.3.0 → 1.0.0): breaking changes or public release

**Rules:**
- Bump the version in the PR that introduces the change, not in a separate PR
- Multiple bug fixes in one PR = one patch bump
- Multiple features in one PR = one minor bump
- Always update both `CFBundleShortVersionString` (e.g. `0.4.0`) and `CFBundleVersion` (e.g. `0.4`)
- You MUST check and bump the version on every PR — do not wait for the user to remind you
- **Also update `CHANGELOG.md` in the same PR as the version bump.** Add a new `## [X.Y.Z] - YYYY-MM-DD` section above the previous entry, using the existing `### Added` / `### Changed` / `### Fixed` headings. This was missed for 0.32.1 (version bumped, changelog left undocumented) and had to be backfilled after the fact — don't let the version and the changelog drift apart.

## Releasing

Only do this when the user explicitly asks to cut/tag/publish a release — not automatically after merging a PR.

1. Bump the version and update `CHANGELOG.md` (should already be done in the merge PR, per above — backfill on `main` first if it wasn't).
2. Tag the merge commit on `main`: `git tag vX.Y.Z <commit>` (lightweight tag, matching every existing tag in this repo) then `git push origin vX.Y.Z`.
3. Build the installer: `bash create-dmg.sh` — builds, signs, and packages `iQualize-X.Y.Z.dmg` in the repo root.
4. Publish the GitHub Release with the DMG attached: `gh release create vX.Y.Z iQualize-X.Y.Z.dmg --title "vX.Y.Z — <short description>" --notes "..."`. Look at a recent release (`gh release view vX.Y.Z-1`) for the notes format — highlights list, a link to the CHANGELOG diff, and the Gatekeeper `xattr -dr com.apple.quarantine` install instructions.
5. Publishing a Release (step 4) is a distinct public action from tagging (step 2) — confirm with the user separately before running `gh release create`, even if they already approved the tag.

## Task Tracking

Use GitHub Issues for backlog and todos. At the start of each session, check `gh issue list` for open work.

- **bug**: something broken
- **feature**: new functionality
- **polish**: UI/UX improvements

When closing a task via PR, use "Fixes #N" in the PR body to auto-close the issue.

## Build & Install

```bash
bash install.sh          # builds, signs with Apple Development cert, installs to /Applications
open /Applications/iQualize.app
```

## Dev Workflow

- Build with `swift build` (SPM, no Xcode project)
- After code changes: `pkill -x iQualize; bash install.sh && open /Applications/iQualize.app`
- Binary is codesigned with "Apple Development" cert to preserve TCC permissions across rebuilds
- install.sh skips binary copy if unchanged (preserves cdhash)

### Launch verification (REQUIRED)

After every build+install, you MUST verify the app actually launches:

```bash
pkill -x iQualize; bash install.sh && open /Applications/iQualize.app
sleep 2
pgrep -x iQualize > /dev/null && echo "OK: app running" || echo "FAIL: app did not start"
```

If the app fails to launch ("can't be opened" error), debug and fix before proceeding. Common causes:
- **TCC/cdhash mismatch**: the codesign identity changed or install.sh didn't re-sign properly
- **Launchd spawn failure**: macOS sometimes needs a few seconds after killing the old process — add `sleep 1` before `open`
- **Crash on startup**: run the binary directly to see the error: `/Applications/iQualize.app/Contents/MacOS/iQualize`

**A task is not done until the app launches successfully.** Never skip this step.

## Architecture

- `Sources/iQualize/iQualizeApp.swift` — app entry, NSApplicationDelegate
- `Sources/iQualize/MenuBarController.swift` — menu bar icon + dropdown
- `Sources/iQualize/EQWindowController.swift` — standalone EQ window (sliders, inputs, presets, spectrum visualization)
- `Sources/iQualize/SettingsWindowController.swift` — global Settings window (Audio, Display, General sections)
- `Sources/iQualize/AudioEngine.swift` — system audio capture + AVAudioEngine EQ processing
- `Sources/iQualize/EQPreset.swift` — state persistence + preset data model
- `Sources/iQualize/EQModels.swift` — EQBand, EQPresetData, PresetStore
- `Sources/iQualize/BiquadResponse.swift` — biquad filter frequency response calculation (Audio EQ Cookbook)
- `Sources/iQualize/SpectrumAnalyzer.swift` — real-time FFT spectrum analysis via Accelerate vDSP
- `Sources/iQualize/SpectrumData.swift` — lock-free double-buffered audio-to-UI data transfer
- `Sources/iQualize/ColorHex.swift` — NSColor ↔ #RRGGBB sRGB hex helpers for persisting user-picked spectrum colors
- `Sources/iQualize/HelpRenderer.swift` — extracts the README's Features section and renders it as HTML via swift-markdown
- `Sources/iQualize/HelpWindowController.swift` — WKWebView-based Help window; intercepts link clicks to open them in the default browser
