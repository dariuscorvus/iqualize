<p align="center">
  <img src="./icon.png" width="128" alt="iQualize app icon">
</p>

# iQualize

> macOS doesn't have a system-wide parametric EQ.
> So I built one in a day.

![iQualize at 04:57](./preview.webp)

Built at 04:57 in Bavaria, listening to [Opera by Ballarak](https://open.spotify.com/track/6EkjiVchNqlYHoc2YNMiaV) on a Teufel Concept E 5.1.
That's the only explanation you need for why this exists.

---

## What it is

A native macOS system-wide parametric EQ with a real-time Pre/Post spectrum analyzer.
No virtual audio drivers. No Electron. No paywall.
Just Swift, CoreAudio, and a CATap doing what they should've always done.

## Why not eqMac

The install process was a hassle. The UI was tiny and fiddly. Half of what I needed was behind a "Pro" paywall. Then my Mac crashed and took the software down with it. That's the actual reason iQualize exists.

eqMac uses a virtual audio driver. iQualize uses a CATap — Apple's native system audio tap introduced in macOS 14. No driver to install. No driver to break. No driver to fight with Bluetooth. It just works.

## Requirements

- macOS 14.2+ (Core Audio Taps API)
- System Audio Recording permission

## Install

### Download (recommended)

Grab the latest `.dmg` from [Releases](https://github.com/DariusCorvus/iqualize/releases), open it, and drag iQualize to Applications.

iQualize is unsigned — Apple charges $99/year for a developer certificate and the app isn't notarized. macOS puts a quarantine flag on anything downloaded from the web, and for an unsigned app that shows up as **"iQualize is damaged and can't be opened"** (macOS Sequoia/Tahoe) or a generic "unidentified developer" block. It isn't actually damaged. After dragging it to Applications, clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/iQualize.app
```

Then open it normally. If the `.dmg` itself won't mount, clear the flag on the download first: `xattr -c ~/Downloads/iQualize-*.dmg`.

### Build from source

```bash
bash install.sh          # builds, signs, installs to /Applications
open /Applications/iQualize.app
```

## Features

### Parametric EQ

- Up to 31 bands with editable frequency (20 Hz – 20 kHz), gain, and bandwidth
- Q / Octave display toggle — switch between Q factor and octave bandwidth globally (Q is the default, octaves for musicians who think in bandwidth)
- 7 filter types per band: Bell (parametric), Low Shelf, High Shelf, Low Pass, High Pass, Band Pass, and Notch
- Biquad frequency response curve using Audio EQ Cookbook formulas, rendered as a translucent backdrop behind EQ sliders
- Per-band ghost fills, anchor dots with dB labels, and split boost/cut composite fill
- Axis labels and detailed frequency/dB grid overlay
- Adjustable max gain range: ±6, ±12, ±18, or ±24 dB — or auto-scale to fit the current curve (up to ±24 dB)
- Input gain (±24 dB) — pre-EQ level control for proper gain staging
- Output gain (±24 dB) — post-EQ level control, applied before the peak limiter
- In/Out dB can be shared globally across all presets, or set per-preset — toggle in Settings → General (see Presets and Settings below)
- Dynamic peak limiter (AUPeakLimiter) — prevents digital clipping at 0 dBFS
- Only changed parameter values are written to the audio unit — no audible glitches on slider drags

### Band Management

- Add bands with + buttons on either side of the EQ — new band copies the leftmost or rightmost band
- Right-click context menu: Add Suggested Band finds the largest frequency gap and inserts a new band at the geometric midpoint
- Delete, or reorder via the right-click context menu (Move Left/Right)
- Minimum 1 band, maximum 31

### Presets

- Built-in presets: Flat, Bass Boost, Vocal Clarity, Loudness, Treble Boost, Podcast, Techno, Deep House, Hard Techno, Minimal, American Rap, German Rap, Luzifer's Void, DEADBEEF, 0xDEADBEEF
- Create, rename, overwrite, and delete custom presets
- Built-in presets can be deleted too (except Flat) if you don't want them cluttering your picker — bring a deleted one back anytime from the Preset Browser's iQualize tab
- Built-in presets auto-fork when edited (non-destructive)
- In/Out dB gain can be stored per-preset (default) or shared globally across all presets — see Settings → General
- Unsaved changes indicator (asterisk in title)
- Import/export as `.iqpreset` JSON files with batch import and overwrite protection — also accepts AutoEQ `ParametricEQ.txt`/`GraphicEQ.txt` and OPRA `eq_info.json` files
- Preset Browser: an OPRA tab to search and import community headphone/IEM EQ profiles directly from the [OPRA](https://opra.roon.app/) database, and an iQualize tab to restore any built-in presets you've deleted
- Quick switching from the menu bar or EQ window picker — both use the same native preset picker, with Favorites, Built-in, and Custom sections
- Favorite presets (star icon, or ⌥-click a preset) to pin them to the top of the picker for one-click switching
- Pin a preset to an output device (pin button in the EQ window toolbar, or from the menu bar) — it's recalled automatically whenever that device becomes the active audio output, including at launch

#### Preset Format

Presets are `.iqpreset` files — plain JSON:

```json
{
  "bands": [
    { "bandwidth": 1.0, "filterType": "parametric", "frequency": 80, "gain": 5 },
    { "bandwidth": 1.2, "filterType": "lowShelf", "frequency": 200, "gain": -3 }
  ],
  "id": "CDE9BB8A-12A5-420C-9619-2790E20030D5",
  "isBuiltIn": false,
  "name": "My Preset"
}
```

Each band: `frequency` (Hz, 20–20000), `gain` (dB), `bandwidth` (octaves, 0.05–10 — 1.0 = one octave ≈ Q 1.41), `filterType` (one of `parametric`, `lowShelf`, `highShelf`, `lowPass`, `highPass`, `bandPass`, `notch` — defaults to `parametric` if omitted).

Presets may also carry `inputGainDB` and `outputGainDB` (dB, optional — omitted or absent means 0 dB, and they're only applied when In/Out dB is in per-preset mode; see Settings → General).

### Undo/Redo

- Full undo/redo for all EQ modifications (gain, frequency, bandwidth, reorder, add, delete)
- Slider drags coalesced into single undo actions
- Cmd+Z / Cmd+Shift+Z

### Keyboard & Scroll

- Click a band or drag its slider to select it (accent-colored border indicator)
- Arrow Up/Down to adjust gain (±0.5 dB per step)
- Arrow Left/Right to adjust frequency (semitone steps)
- Tab / Shift+Tab to cycle between bands
- Scroll wheel over sliders to adjust gain
- Scroll wheel over frequency/Q inputs to adjust those values
- Cmd+B — toggle Bypass EQ (works from the EQ window or menu bar)
- Cmd+, — open Settings
- Rapid adjustments coalesced into single undo entries

### Menu Bar

- Open iQualize — first item in the menu for quick access
- Option+click the menu bar icon to open the EQ window directly (skips the menu)
- Presets submenu with checkmarks and active preset name in parent item — changes sync to the EQ window in real time
- Bypass EQ toggle (Cmd+B) — pass audio through unprocessed; while bypassed, the Post-EQ spectrum line and its color/fill controls are hidden/disabled (post-EQ would otherwise just mirror pre-EQ)
- Current output device display, with a pin/unpin item to remember a preset for that specific device
- Help… (Cmd+?) — opens an in-app Help window rendering the README's Features section, with a "View latest on GitHub" link
- About iQualize — shows version and a "View on GitHub" button that opens the project page in your default browser

### Settings

Accessible via the gear icon in the EQ window, the Settings item in the menu bar, or Cmd+,.

- **Audio**: Peak Limiter toggle, Max Gain range (±6/12/18/24 dB), Auto Scale toggle
- **Display**: Pre-EQ / Post-EQ spectrum toggles, per-spectrum line color picker, per-spectrum Fill toggle with its own color picker, reset buttons to return to the dynamic system colors, Q / Octave bandwidth display toggle
- **General**: Theme (Auto / Light / Dark), Hide from Dock toggle, Start at Login toggle, Share In/Out dB across all presets toggle, Install Command Line Tool button

### Spectrum Analyzer

- Dual real-time spectrum analyzer: pre-EQ (raw input) and post-EQ (processed output)
- Independent toggle checkboxes for pre-EQ and post-EQ display
- 2048-point FFT via Accelerate vDSP with Hann windowing and log-frequency binning
- Catmull-Rom spline rendering with peak hold lines
- Lock-free double-buffered audio-to-UI transfer, so 60fps UI updates never block on the audio thread
- Customizable line and fill colors per spectrum (Settings → Display) — defaults to cyan for pre-EQ, orange for post-EQ, both adapting to Light and Dark appearance; reset returns to the dynamic system color
- Per-spectrum fill toggle (off by default for pre-EQ, on for post-EQ) with its own color, independent from the line color
- Post-EQ spectrum auto-hides when EQ bypass is active (post-EQ would otherwise just mirror pre-EQ)
- Spectrum toggle states, fill toggles, and color choices persist across app restarts

### Stereo Balance

- L/R balance slider in the bottom bar, centered by default
- Snap-to-center with double-click reset
- Applied as per-channel gain in the audio render callback

### System Integration

- AirPods hand off automatically between your Mac and iPhone mid-playback (Apple Continuity), the same as any other app — no need to quit iQualize or manually switch output first
- Automatic output device switching and reconnection
- Apps launched after iQualize is already running get picked up into the EQ automatically, no restart needed
- Sleep/wake handling — pauses on sleep, resumes on wake
- Window state and all settings persist across launches
- Codesigned for stable TCC permissions across rebuilds
- Built with Swift Package Manager — no Xcode project needed

### Command Line

Control a running iQualize instance from the terminal — skip the menu bar entirely, and
script iQualize with it: Shortcuts, launchd jobs, keyboard-shortcut launchers, etc.

**Setup (one-time):** open iQualize → Settings (Cmd+,) → General → **"Install Command
Line Tool"**. This prompts for your admin password once and adds `iqualize` to your
PATH. Open a **new** Terminal window afterward — a window that was already open won't
pick it up. (Building from source instead? `install.sh` symlinks it automatically, no
button needed.)

```
iqualize                      # same as `iqualize status`
iqualize status               # bypass state, active preset, gain, output device
iqualize presets               # list all presets (* = active, ♥ = favorite)
iqualize preset "Bass Boost"   # switch the active preset by name or ID
iqualize bypass [on|off|toggle]
iqualize gain input [<dB>]     # omit the value to read the current one
iqualize gain output [<dB>]
```

If iQualize isn't running, the CLI launches it and retries for about 5 seconds before
giving up. If Terminal still says `command not found` after installing, double-check
you opened a new window/tab, and that `/usr/local/bin` is on your `PATH` (`echo $PATH`).

## Architecture

> For the long version — why CATap, what fought back, and how the audio graph came together — read the blog post: [Building iQualize - A System-Wide EQ That Doesn't Suck](https://darius.codes/writing/building-iqualize).

iQualize uses Core Audio Taps (CATap), introduced in macOS 14.2, to intercept system audio without a virtual audio device. Virtual devices (like BlackHole) create a secondary audio path — you lose system volume control, break some DRM-protected audio, and add latency. CATap captures the audio stream directly from the HAL and processes it before it reaches the output device.

The tap and IOProc run in a small helper process (`iQualizeCapture`), separate from the app that renders the processed audio. A process that both holds an active tap and drives the render stream on the same output device gets treated by `coreaudiod` as non-preemptible — which silently blocks AirPods from auto-switching between your Mac and iPhone (Apple Continuity). Splitting tap-ownership from rendering into two processes keeps that path free, so Continuity handoff works the same as it would with any other app.

```mermaid
flowchart LR
    subgraph capture["iQualizeCapture (helper process)"]
        direction TB
        apps["App Audio"] -->|CATap| aggregate["Tap-only Aggregate Device"]
        aggregate -->|IOProc| shm[("Shared Memory<br/>Ring Buffer")]
    end

    subgraph main["iQualize (main process)"]
        direction TB
        source["AVAudioSourceNode"] --> eq["AVAudioUnitEQ<br/>(parametric EQ)"]
        eq --> gain["Output Gain Node"]
        gain --> limiter["AUPeakLimiter"]
    end

    shm -->|CaptureClient| source
    apps -.->|muted by tap| device["Output Device"]
    limiter -->|AVAudioEngine outputNode| device
```

The shared-memory ring buffer decouples the helper's real-time IOProc callback from the main app's AVAudioEngine pull model — no locks in the audio thread, no glitches on slider drags. If the helper process ever dies unexpectedly, the main app detects it and stops cleanly rather than leaving audio in a broken state.

## Output Handling

iQualize captures audio at the tap's native sample rate; AVAudioEngine's output node converts it to whatever rate the current output device needs, so playback stays correct across device switches. Bluetooth sends stereo (2ch) only — SBC, AAC, and aptX all max out at 2 channels. If your speaker system supports 5.1 — a Teufel Concept E via USB, say — the hardware handles channel routing and upmixing (Dolby Pro Logic II etc) on its end.

## Credits

The Preset Browser's headphone and IEM EQ profiles come from the [OPRA project](https://github.com/opra-project/OPRA) — Open Profiles for Revealing Audio, an open, community-maintained directory of product information and EQ compensation curves. OPRA's data is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); each imported profile credits its original author in the browser.

---

I build tools that shouldn't need to exist.

[darius.codes](https://darius.codes)
