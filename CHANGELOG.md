# Changelog

All notable changes to iQualize will be documented in this file.

## [0.37.1] - 2026-07-12

### Fixed
- Gain-slider edits in the EQ window while per-preset In/Out dB is active now correctly persist the forked "(Custom)" preset as the selected preset, so it's still active after quitting and relaunching instead of silently reverting to the original built-in preset

## [0.37.0] - 2026-07-12

### Added
- Built-in presets can now be deleted (except Flat, which stays as a safe fallback) — useful if you don't want the app's more opinionated presets (Hard Techno, German Rap, DEADBEEF, etc.) cluttering your picker. Deleted ones aren't gone for good: the Preset Browser (Save/Import menu → "Preset Browser…") now has an **iQualize** tab alongside OPRA, listing anything you've deleted with a one-click Restore

## [0.36.0] - 2026-07-12

### Added
- Preset Browser: search and import community headphone/IEM EQ profiles directly from the OPRA database (opra.roon.app) without hunting down and downloading a file first. Browse by vendor/product, pick from the available community-contributed curves for that model, and import in one click — reuses the existing AutoEQ/OPRA import path under the hood

## [0.35.0] - 2026-07-12

### Added
- Import Preset… now also accepts AutoEQ `ParametricEQ.txt`/`GraphicEQ.txt` and OPRA `eq_info.json` files alongside iQualize's own format, so community EQ profiles for headphones/IEMs can be dropped in directly. GraphicEQ curves are resampled onto the app's 31-band ceiling; each format's preamp/gain value is carried over as the preset's input gain

### Changed
- Per-preset In/Out dB is now the default for new installs, instead of sharing one gain value across all presets — matches the imported preamp/gain value from AutoEQ/OPRA presets landing on the preset itself rather than being silently ignored until "Share In/Out dB across all presets" was manually turned off in Settings

## [0.34.0] - 2026-07-11

### Added
- Pin/favorite presets so they show at the top of both the menu bar dropdown and the in-app preset picker for one-click switching, instead of always having to dig into the full preset list (#80). ⌥-click any preset to pin/unpin it; a pin marks favorited presets in the full list

## [0.33.0] - 2026-07-11

### Added
- Per-preset In/Out dB — input and output gain can now be stored on each preset individually, so switching presets restores that preset's gain
- New "Share In/Out dB across all presets" toggle in Settings → General to keep the previous behavior of one shared gain value across all presets (on by default, preserving existing behavior)
- Adjusting In/Out dB on a built-in preset while per-preset mode is on forks it into a "(Custom)" copy, matching how band edits already fork built-ins

## [0.32.2] - 2026-07-11

### Fixed
- iQualize no longer requests the combined Screen & System Audio Recording permission on launch. `AudioHardwareCreateProcessTap` already triggers its own narrower TCC prompt scoped to system audio only (`NSAudioCaptureUsageDescription`), so the eager `CGRequestScreenCaptureAccess` call was asking for more access than the app actually needs (#83)

## [0.32.1] - 2026-07-11

### Fixed
- Pre/Post-EQ spectrum line and fill colors now respect the custom colors set in Settings → Display, instead of the Dream UI canvas silently ignoring them and drawing hardcoded colors with the fill defaults inverted (#81)
- "Output:" device name no longer stretches the window on long names — it truncates and sits in its own centered row below the footer controls
- Band dB/Hz readouts on the graph now only show for the selected/hovered band, instead of showing on every knob at once and overlapping when bands sit close in frequency
- ±12/±18/±24 range control now acts as a toggle: clicking a value turns off Auto-scale and applies that range immediately, instead of silently being overridden while still looking selectable — this was the real bug behind the "±12 selected but axis shows ±24" report in #81
- Band knobs at the 20 Hz/20 kHz frequency extremes no longer get clipped by the canvas edge; the pre/post-EQ spectrum trace now reaches the canvas edges to match

### Changed
- Footer reorganized: Bypass moved to the start of row 2, Q/Oct moved to the end of row 2 (after Peak Limiter), Auto-scale moved right after the ±12/±18/±24 control

## [0.32.0] - 2026-06-29

### Fixed
- In/Out gain is now applied at startup. Previously the saved input/output gain was not pushed to the audio engine on launch, so audio played at unadjusted levels until the EQ window was opened for the first time (#74)

## [0.31.0] - 2026-06-29

### Changed
- Dream EQ footer reorganized into two purpose-based rows with subtle group dividers: row 1 is signal (Bypass, Peak Limiter, In/Out/Balance, Channel, Output), row 2 is display (Pre-EQ, Post-EQ, Q/Oct, max gain, Auto-scale)
- Add-band "+" buttons inset from the canvas edges so they no longer crowd the frame
- Theme (Auto/Light/Dark) moved out of the EQ toolbar into Settings → General — it's rarely changed, so the toolbar now carries just Snap and the gear
- Snap toggle is now a magnet icon (icon-only, with a hover tooltip) instead of the "♪ Snap" label

### Fixed
- "Out:" gain label no longer wraps onto a second line; In/Out/Bal labels and values share a consistent width
- Inline cell editing and the empty-checkbox fill are now legible in Light mode (previously white-on-light)
- Re-selecting a band's current filter type no longer forks a built-in preset to "(Custom)" or pushes a redundant undo step
- Undo now clears the "modified" dirty dot once the EQ curve is back to the saved values (a phantom dot previously lingered after undoing a built-in→Custom fork)

## [0.30.2] - 2026-05-23

### Fixed
- Removed the unused band-reorder grab-handle row from the Dream EQ readout grid (#70)

## [0.30.1] - 2026-05-08

### Fixed
- Dream UI filter-type dropdown now reliably opens, commits the selection, and stays cell-width

## [0.30.0] - 2026-05-02

### Changed
- **Brand-new SwiftUI "Dream" EQ window** — the EQ surface was rebuilt from scratch on a SwiftUI `Canvas`, replacing the old AppKit drawing internals while keeping the same audio engine, preset store, and persisted state. The chart renders dB/Hz axes, real pre/post-EQ spectrum, smoothed Catmull-Rom traces, per-band ghost responses, and a live composite curve, with draggable knobs and bandwidth handles directly on the canvas.
- Band values now live in a five-row readout grid below the canvas: single-click to activate a cell, scroll-wheel to adjust, inline editing, and a native filter-type dropdown.
- Toolbar uses native macOS menus for the preset picker, the Save split-button, and the theme cycle; Import/Export and Save As use native dialogs.
- Auto-scale dynamically resizes the dB axis to fit the composite curve, with vertical padding so the +max/−max labels don't clip.
- Window opens at a tighter 880×600 (was 1200×740); the native title bar shows "iQualize — <preset>" with a dirty-marker dot for unsaved changes.

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
