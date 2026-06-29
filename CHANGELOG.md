# Changelog

All notable changes to iQualize will be documented in this file.

## [0.31.0] - 2026-06-29

### Changed
- Dream EQ footer reorganized into two purpose-based rows with subtle group dividers: row 1 is signal (Bypass, Peak Limiter, In/Out/Balance, Channel, Output), row 2 is display (Pre-EQ, Post-EQ, Q/Oct, max gain, Auto-scale)
- Add-band "+" buttons inset from the canvas edges so they no longer crowd the frame

### Fixed
- "Out:" gain label no longer wraps onto a second line; In/Out/Bal labels and values share a consistent width
- Inline cell editing and the empty-checkbox fill are now legible in Light mode (previously white-on-light)

## [0.29.0] - 2026-05-02

### Added
- In-app Help window (Cmd+? or "Help…" in the menu bar dropdown) renders the README's Features section directly inside the app — no need to leave for GitHub. Includes a "View latest on GitHub" link for content newer than your installed build (#60, suggestion #8)
- Standard macOS **Window** and **Help** menus in the OS menu bar (visible when Hide from Dock is off) — Window auto-lists open iQualize windows for keyboard navigation; Help mirrors the in-app Help shortcut

## [0.28.0] - 2026-05-01

### Added
- About iQualize alert now has a "View on GitHub" button that opens the project page in your default browser (#60)
- Custom Pre-EQ and Post-EQ spectrum colors — each spectrum has a line color and an optional fill (with its own color) in Settings → Display, with reset buttons to return to the dynamic system color. Pre-EQ now supports fill too (off by default; Post-EQ defaults to on, matching the previous look)

### Changed
- Post-EQ Spectrum checkbox is disabled and the post-EQ line is hidden while EQ is bypassed (post-EQ would just mirror pre-EQ in that state); your preference is preserved and restored when bypass turns off

## [0.27.1] - 2026-04-23

### Fixed
- Menu bar preset changes now sync to the EQ window (picker, sliders, curve)
- Spectrum lines visible in Light mode — pre-EQ is cyan, post-EQ is orange (previously both white, invisible on light backgrounds)
- Cmd+B (Bypass EQ) and Cmd+, (Settings) now work as global keyboard shortcuts from the EQ window via the main menu bar
- Pre/Post-EQ spectrum toggle state syncs from EQ window to Settings window
- Dragging a slider selects that band for arrow key navigation

## [0.27.0] - 2026-04-13

### Changed
- Dock quit now hides to menu bar instead of terminating — right-clicking the dock icon and choosing Quit closes windows and hides the dock icon, but iQualize keeps running in the menu bar with audio processing active. Use the menu bar's "Quit iQualize" or Cmd+Q to fully quit.

## [0.26.0] - 2026-04-13

### Added
- DEADBEEF built-in preset — 10-band parametric EQ derived from `0xDEAD` (sub) and `0xBEEF` (presence) hex values, fine-tuned for dark techno
- 0xDEADBEEF built-in preset — 20-band pure math experiment where every frequency is a bit-shift of `0xDEAD` or `0xBEEF`, with alternating boost/notch pairs at each octave

## [0.25.0] - 2026-04-13

### Added
- Luzifer's Void built-in preset — 16-band parametric EQ for dark techno, bunker techno, and perverted tech with gravitational sub mass, gutted mids, and a rising high-end staircase

## [0.24.0] - 2026-04-13

### Added
- Global Settings window — consolidates Peak Limiter, Max Gain, Auto Scale, Pre/Post-EQ Spectrum, Bandwidth mode, Hide from Dock, and Start at Login into a dedicated settings panel (Cmd+,)
- Gear icon in EQ window bottom bar to open Settings directly
- Two-row bottom bar layout — top row for session controls (bypass, gain, balance, channel mode), bottom row for display and audio settings
- Bidirectional sync between Settings window and EQ window controls

### Changed
- Menu bar streamlined — Peak Limiter, Hide from Dock, and Start at Login moved to Settings window
- "Open iQualize" no longer uses Cmd+, shortcut (reassigned to Settings)

### Fixed
- `syncMaxGain` now calls `updateCurveView()` so the response curve redraws when gain range changes from Settings
- Force-unwrap on `NSImage(systemSymbolName:)` replaced with safe fallback

## [0.23.0] - 2026-04-01

### Added
- Q/Octave bandwidth display toggle — bandwidth values now display as Q factor (default) or octaves, with correct conversion using Audio EQ Cookbook formulas

## [0.22.0] - 2026-04-01

### Added
- Input and output gain controls with dB sliders in the bottom bar
- Menu bar UX improvements

## [0.21.0] - 2026-04-01

### Added
- Per-channel L/R EQ with split channel mode — apply different EQ settings to left and right channels independently
- Channel mode selector (Linked/L/R) in the bottom bar


## [0.19.0] - 2026-04-01

### Added
- Stereo balance control — L/R balance slider in the bottom bar with snap-to-center and double-click reset
- Balance persists across app restarts

### Fixed
- Menu bar actions (toggle bypass, open/close window, switch preset) no longer overwrite settings saved by the EQ window

## [0.18.0] - 2026-03-31

### Added
- Start at Login toggle in menu bar — launch iQualize automatically when you log in, using macOS ServiceManagement (no helper app needed)

## [0.17.0] - 2026-03-30

### Changed
- Presets now live in a dedicated submenu in the menu bar, with the active preset name visible at a glance
- Pre-EQ spectrum is now a subtle white ghost line instead of a filled shape
- Post-EQ spectrum switched from teal to monochrome white fill for a cleaner pro-audio look
- Spectrum layers now draw in correct z-order for proper visual stacking
- Peak hold lines unified to subtle white for a cohesive monochrome spectrum

## [0.16.0] - 2026-03-30

### Added
- Dual real-time spectrum analyzer with pre-EQ (raw input) and post-EQ (processed output) visualization
- Independent toggle checkboxes for pre-EQ and post-EQ spectrum display
- Smooth Catmull-Rom spline rendering for spectrum curves with peak hold lines
- Lock-free double-buffered audio-to-UI data transfer using ARM64 natural atomicity
- 2048-point FFT via Accelerate vDSP with Hann windowing and log-frequency binning
- Asymmetric smoothing: instant attack, exponential decay (factor 0.85) for responsive yet smooth visuals
- Spectrum toggle states persist across app restarts

## [0.15.1] - 2026-03-30

### Removed
- "Low Latency" toggle from EQ window and menu bar — it only changed ring buffer capacity without meaningfully reducing latency, while increasing audio glitch risk

## [0.15.0] - 2026-03-30

### Changed
- Replace static "Prevent Clipping" with a real dynamic peak limiter using Apple's AUPeakLimiter
- Rename "Prevent Clipping" to "Peak Limiter" in menu bar and EQ window
- Rename `preventClipping` property and JSON key to `peakLimiter`

### Removed
- Static preamp gain reduction (`preampGain` computed property)
- Legacy state migration code (no existing users to migrate)

## [0.13.0] - 2026-03-30

### Added
- Keyboard shortcuts for EQ band adjustments: Arrow Up/Down for gain (±0.5 dB), Arrow Left/Right for frequency (semitone steps)
- Tab/Shift+Tab to cycle selection between bands
- Visual selection indicator with accent-colored border on the active band
- Scroll wheel support: hover over sliders, frequency inputs, or Q inputs to adjust values by scrolling
- Click-to-select on band columns clears text field focus for immediate keyboard control
- Undo coalescing for rapid keyboard and scroll adjustments (500ms timer groups into single undo entry)

## [0.11.0] - 2026-03-30

### Added
- Accurate biquad frequency response curve using Audio EQ Cookbook formulas, showing the true filter response behind the EQ sliders
- Per-band ghost fills showing individual filter contribution shapes
- Anchor dots with drop lines and dB labels at each band's frequency on the composite curve
- Split composite fill (boost regions brighter than cut regions)
- Detailed frequency/dB grid (20Hz–20kHz vertical, 6dB horizontal)
- Axis labels (+12, 0, -12 dB) in the left margin outside the graph area
- American Rap built-in preset (808-heavy sub-bass, mid scoop, vocal presence)
- German Rap built-in preset (warm mid-bass, vocal clarity, balanced brightness)

### Changed
- Spline curve (connecting slider knobs) now rendered as a dashed gray line to distinguish from the biquad response
- install.sh now re-signs the app when only Info.plist changes (fixes launch failures after version bump)

## [0.10.0] - 2026-03-30

### Added
- Per-band filter type selection with 7 filter types: Bell (parametric), Low Shelf, High Shelf, Low Pass, High Pass, Band Pass, and Notch
- Frequency response curve rendered as a backdrop behind EQ sliders
- Per-filter-type curve shapes that visually match each filter's behavior
- Catmull-Rom spline interpolation for pixel-perfect curve-to-handle alignment
- Notch (band stop) filter type for surgical frequency cuts

### Changed
- Response curve is now always visible as a translucent backdrop behind sliders (replaced collapsible standalone panel)
- `isFlat` check now considers filter type (non-parametric bands are not "flat")
- Add-band operations now copy the reference band's filter type

### Fixed
- Curve alignment with slider handles across all band configurations
- Coordinate conversion through flipped/non-flipped view hierarchies
- Frequency response curve now updates when changing a band's filter type
- Guard against division by zero with zero-bandwidth parametric bands
