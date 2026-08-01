# iQualize

macOS menu bar audio equalizer using system audio capture + AVAudioEngine.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): `<type>[optional scope]: <description>`.

- **type**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- Breaking change: append `!` after the type/scope (`feat!: ...`) or add a `BREAKING CHANGE:` footer
- Description: imperative mood, lowercase, no trailing period
- This isn't yet reflected in the existing history — apply it going forward, don't rewrite past commits

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
2. Write the curated highlights for the release: `.github/release-notes/highlights/vX.Y.Z.md`. The first line is a title directive — `<!-- title: vX.Y.Z — short summary -->` — and everything after it is a `## Highlights` block of prose bullets (what changed and why it matters, bold lead-ins, issue refs). The workflow reads the title from that directive and prepends the block above the install note. Without this file the release falls back to a generic `iQualize vX.Y.Z` title and no highlights, so don't skip it. Land it in the merge PR alongside the version bump, or commit it to `main` before tagging.
3. Tag the merge commit on `main`: `git tag vX.Y.Z <commit>` (lightweight tag, matching every existing tag in this repo) then `git push origin vX.Y.Z`. **This is the action that publishes the release** — pushing a `v*` tag starts the `Release` workflow (`.github/workflows/release.yml`), which runs the tests, builds and verifies the universal DMG, notarizes it if the `APPLE_*` secrets are configured, and creates the GitHub Release itself (curated title + highlights, auto-generated `What's Changed`, thanks section, DMG attached). Confirm with the user before pushing the tag, not after — there's no separate manual publish step to gate on.
4. To dry-run the build without publishing anything, trigger the workflow manually instead of pushing a tag: `gh workflow run release.yml` — runs tests, builds and verifies the DMG, and uploads it as a workflow artifact; no release is created.
5. Only if CI fails and a release genuinely needs to be built or published by hand: `bash scripts/create-dmg.sh` builds, signs, packages, and verifies `iQualize-X.Y.Z.dmg` in the repo root (it runs `scripts/verify-dmg.sh` and aborts if the app inside has a broken/invalid signature — the state macOS reports as "damaged", issue #115), then `gh release create vX.Y.Z iQualize-X.Y.Z.dmg --title "vX.Y.Z — <short description>" --notes "..."` (check a recent release's format with `gh release view vX.Y.Z-1` — highlights list, CHANGELOG diff link, Gatekeeper `xattr -dr com.apple.quarantine` instructions). A `PreToolUse` hook (`.claude/settings.json`) blocks a `gh release create`/`gh release upload` that attaches a DMG failing that same verification. Unsigned builds need `xattr -dr com.apple.quarantine` after download.

## Task Tracking

Use GitHub Issues for backlog and todos. At the start of each session, check `gh issue list` for open work.

- **bug**: something broken
- **feature**: new functionality
- **polish**: UI/UX improvements

When closing a task via PR, use "Fixes #N" in the PR body to auto-close the issue.

## Build & Install

```bash
bash scripts/install.sh          # builds, signs, installs to /Applications
open /Applications/iQualize.app
```

## Dev Workflow

- Build with `swift build` (SPM, no Xcode project)
- After code changes: `pkill -x iQualize; bash scripts/install.sh && open /Applications/iQualize.app`
- install.sh signs with `IQ_SIGN_IDENTITY` if set, else an installed "Apple Development" cert, else ad-hoc. Ad-hoc TCC grants pin the cdhash: no-op reinstalls keep it (the re-sign is deterministic), but any real code change gets a fresh TCC prompt — only a cert-based signature survives those
- install.sh skips binary copies when the fresh build products match the hashes recorded in `Contents/Resources/build-hashes` at the last install. Installed binaries themselves never byte-match a fresh product — signing rewrites them — so don't compare against those

### Launch verification (REQUIRED)

After every build+install, you MUST verify the app actually launches:

```bash
pkill -x iQualize; bash scripts/install.sh && open /Applications/iQualize.app
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
