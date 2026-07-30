# EQ Band Capacity

Tracks: [#114](https://github.com/dariuscorvus/iqualize/issues/114)

## Why this document exists

iQualize used to cap presets at 31 EQ bands (`EQPresetData.maxBandCount`). The fix looks like a one-line constant removal, but the actual constraint is a real Core Audio ceiling, not just an app-chosen number, so the fix is a genuine architecture change (a second DSP path spliced into the render callback) rather than a config bump. This file is the in-repo record of *why* 31 was there, why it couldn't just be raised, and what runs in its place — so a future "why does `AudioEngine` still have a `31` in it, didn't we remove the limit?" doesn't require re-deriving all of this from the diff.

## Why 31 wasn't just an app-chosen number

`AudioEngine` did (and still does) all linked-channel-mode EQ processing through `AVAudioUnitEQ`, the system's N-band parametric EQ Audio Unit (backed by Apple's `AUNBandEQ`). It's constructed with a fixed band count up front:

```swift
AVAudioUnitEQ(numberOfBands: EQPresetData.maxBandCount) // was 31
```

`AVAudioUnitEQ.bands` is a fixed-size array allocated at that call — there's no API to grow it afterward. The natural-looking fix ("raise the constant, or grow the node when the user adds more bands") runs into the fact that the underlying `AUNBandEQ` unit has its own hardware/OS-defined ceiling, independent of the app. From Apple's `AudioUnitProperties.h`:

```c
/*!
    @constant       kAUNBandEQProperty_NumberOfBands
    @discussion         ... If more than kAUNBandEQProperty_MaxNumberOfBands
                        are specified, an error is returned.

    @constant       kAUNBandEQProperty_MaxNumberOfBands
    @discussion         Returns the maximum number of equalizer bands.
*/
```

So "just ask for more bands" was never going to produce an unbounded engine — it would only move the wall from 31 to wherever `kAUNBandEQProperty_MaxNumberOfBands` reports on a given system, still an AU-imposed ceiling, still not "CPU-bound only" as the issue asked for.

## What already worked: split-channel mode

Split-channel mode (independent L/R EQ curves) never used `AVAudioUnitEQ` at all. It runs `BiquadFilterChain` (`Sources/iQualize/BiquadFilter.swift`) — a hand-rolled, real-time-safe Direct-Form-II-Transposed biquad chain — directly inside the `AVAudioSourceNode` render callback, with `AVAudioUnitEQ` fully bypassed. `BiquadFilterChain` resizes its internal coefficient/state arrays to whatever `bands.count` it's given; it has no capacity ceiling of its own. This path was already exactly what the issue asked for, just only reachable via split-channel mode.

## The fix: cascade an overflow chain in linked mode

Rather than replace `AVAudioUnitEQ` outright (see "Alternative considered" below), linked mode now splits a preset's bands into two groups:

- **Bands `0..<31`** — processed by `AVAudioUnitEQ`, unchanged from before.
- **Bands `31...`** (if any) — processed by `BiquadFilterChain`, cascaded ahead of `AVAudioUnitEQ` in the render callback, exactly the way split-channel mode already ran its chains, just carrying only the overflow bands instead of the full preset.

`AudioEngine.applyBands()` (previously duplicated between `start()` and `applyBands()`, now a single code path called from both) is where this split happens:

```swift
private static let avEQNativeBandCount = 31   // AVAudioUnitEQ's native capacity
```

The render callback's `rtBiquadChainActive` flag (renamed from `rtSplitChannelActive`, since it's no longer split-mode-specific) now means "run whatever's in `rtBiquadChainL`/`R`" — the content differs by mode, but the callback doesn't need to know which:

- **Split-channel mode**: chains carry the *entire* per-channel band list; `AVAudioUnitEQ` is bypassed. Unchanged from before this fix.
- **Linked mode, ≤31 bands**: chains are `nil`, flag is `false`. Byte-identical code path to before this fix — zero behavior change for the overwhelming majority of presets.
- **Linked mode, >31 bands**: chains carry only bands `31...`, both L and R identical (linked mode shares one band list across channels). `AVAudioUnitEQ` still handles bands `0..<31` and is *not* bypassed.

Because the render callback biquad step runs unconditionally ahead of `AVAudioUnitEQ` in the signal path (it's inside the `AVAudioSourceNode`'s own render block, which returns before the graph ever reaches the `AVAudioUnitEQ` node), the two DSP engines compose correctly: the source node hands `AVAudioUnitEQ` audio that already has the overflow bands applied, and `AVAudioUnitEQ` applies bands `0..<31` on top. Cascaded biquads commute for magnitude response, so band order between the two engines doesn't matter acoustically.

## Alternative considered: replace `AVAudioUnitEQ` entirely

The architecturally "purer" option — always route linked-mode EQ through `BiquadFilterChain` too, dropping `AVAudioUnitEQ` from the graph altogether — was considered and rejected for this pass.

The blocker: the pre-EQ/post-EQ spectrum analyzer overlay (`preEqAnalyzer`/`postEqAnalyzer`, user-toggleable in Settings) gets its data via `AVAudioEngine.installTap` on `sourceNode` (pre) and `eqNode` (post) — see `AudioEngine.swift` `start()`. That only works because `AVAudioUnitEQ` is a real node downstream of the source node in the graph; tapping it is how "post-EQ" is captured today. If EQ moved entirely into the render callback, the source node's own tap would already contain the fully-EQ'd signal, collapsing the pre/post distinction for every user, not just those with >31 bands. Fixing that properly would mean feeding both analyzers manually from inside the render callback (a raw-pointer path into `SpectrumAnalyzer`, since wrapping raw render-callback buffers in `AVAudioPCMBuffer` there would allocate on the audio thread) — a materially bigger, riskier change to the most carefully-guarded code in the app.

The hybrid approach keeps `AVAudioUnitEQ` and its tap points completely untouched for every preset at or under 31 bands (the common case), and only introduces the overflow chain for presets that actually exceed it.

## Known trade-off

For a preset with more than 31 bands, the pre-EQ spectrum view is not perfectly "pre" anymore: the overflow chain (bands 31+) has already been applied by the time `sourceNode`'s tap fires, so `preEqAnalyzer` shows a partially-EQ'd signal in that case. `postEqAnalyzer` (tapping after `AVAudioUnitEQ`) is unaffected and remains fully accurate. This only affects users who exceed the AU's native capacity — the vast majority of presets (10–20 bands is typical; even the AutoEQ/OPRA catalog rarely exceeds it) see no change at all.

## What was removed alongside the AU/engine change

The 31-band ceiling was enforced in more than just `AudioEngine`:

- **CLI**: `MenuBarController.addBand` rejected a 32nd band with an explicit error. Removed — the underlying crash risk it existed to prevent (`eq.bands[i]` out of bounds) no longer exists, because `applyBands` now bounds every AU-array access to `min(count, avEQNativeBandCount)`.
- **Import truncation**: `PresetImporter.parseParametricEQ` (AutoEQ) and `parseOPRA` both truncated to 31 bands after parsing. Removed — imports now keep every band the source file provides.
- **Not removed**: `PresetImporter`'s GraphicEQ import still resamples onto a fixed 31-point ISO 1/3-octave grid (`iso31BandFrequencies`). That's unrelated to the AU capacity — GraphicEQ.txt is a dense continuous curve, not a list of parametric bands, so importing it always means resampling onto *some* fixed grid; 31 is simply how many ISO 1/3-octave centers exist between 20 Hz and 20 kHz. Higher-resolution GraphicEQ import (e.g. 1/6- or 1/12-octave) would be a deliberate, separate change to the importer, out of scope here.
- **Latent GUI bug closed as a side effect**: `DreamViewModel.addBand` (the GUI's "+" buttons and "Add Suggested Band") never had its own band-count guard — only the CLI did. Past 31 bands added via the GUI, the old `eq.bands[i]` indexing in `applyBands` would have been out of bounds. `applyBands`'s new bounded loop (`0..<min(count, avEQNativeBandCount)`) closes this regardless of which client (GUI or CLI) is adding bands.

## Verification

- `Tests/iQualizeTests/BiquadFilterChainTests.swift` exercises `BiquadFilterChain` directly with 40 bands and with a chain grown from 1 to 35 bands, confirming the DSP layer has no built-in ceiling.
- Manually verified against the running app via the CLI: added 105 bands to a live preset (`iqualize band add` in a loop), confirmed `iqualize status` reported zero underruns/resyncs throughout, and confirmed the EQ window rendered the resulting curve and all 105 per-band readout rows without lag or crash.

## Files involved

- `Sources/iQualize/AudioEngine.swift` — `avEQNativeBandCount`, `applyBands`, the render callback's `rtBiquadChainActive`/`rtBiquadChainL`/`rtBiquadChainR`.
- `Sources/iQualize/BiquadFilter.swift` — `BiquadFilterChain`, unchanged; now serves two roles (full split-channel processing, or linked-mode overflow) instead of one.
- `Sources/iQualize/MenuBarController.swift` — CLI `addBand`, cap removed.
- `Sources/iQualize/PresetImporter.swift` — AutoEQ/OPRA import truncation removed; GraphicEQ's ISO grid untouched.
- `Sources/iQualize/EQModels.swift` — `EQPresetData.maxBandCount` removed (kept `minBandCount`).
