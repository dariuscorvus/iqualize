# AirPods Continuity Handoff and iQualize

Tracks: [#71](https://github.com/DariusCorvus/iqualize/issues/71)

## Why this document exists

System-audio EQs on macOS (iQualize, BackgroundMusic, eqMac, etc.) all share one user-visible regression: while the EQ is enabled, AirPods stop auto-handing-off between Mac and iPhone the way they do without the EQ.

We investigated this in depth (`/Users/darius/.claude/plans/investigate-diagnose-the-issue-cuddly-dijkstra.md`). This file is the in-repo summary of what we learned about *why* it happens and *what does or doesn't fix it*, so future work doesn't repeat the same dead ends.

## How AirPods auto-handoff actually works

It's not Bluetooth proximity. AirPods auto-handoff is part of **Continuity** — a layer above Core Audio. Sources: WWDC23 §10233 "Enhance your app's audio experience with AirPods", `AVAudioRoutingArbiter` documentation.

- Each device (Mac, iPhone) broadcasts audio-activity state via encrypted BLE / Wi-Fi Direct.
- Continuity arbitrates which device gets the AirPods based on priority rules: active call > media; manual selection wins for a sticky duration; last-used device wins for ambient cases.
- The losing device is supposed to release the AirPods at the Core Audio level so the winning device can claim them.

There is no public Core Audio API to detect "Continuity is asking for this device, please release". The mechanism is one-way: Continuity *expects* the loser to yield because of how Mac apps typically use AVAudioEngine.

## Why iQualize blocks the handoff

iQualize's architecture (see `Sources/iQualize/AudioEngine.swift`) holds the output device through two paths:

1. **Aggregate device claim**. `AudioHardwareCreateAggregateDevice` creates an aggregate where the user's output device (e.g. AirPods) is the main subdevice. `AudioDeviceStart` runs an IOProc on this aggregate. From Core Audio's perspective, the aggregate *owns* the AirPods.
2. **AVAudioEngine output unit claim**. `kAudioOutputUnitProperty_CurrentDevice` is set on the engine's output AudioUnit, pinning it to the AirPods. When the AU is running, it holds the device.

Both claims are at a lower level than Continuity's arbitration. Apple's `AVAudioRoutingArbiter` is meant to make AVAudioEngine apps cooperate with Continuity, but it does not actually release these low-level claims.

Net effect: Continuity tries to move the AirPods, the claims block the move, and silently nothing happens. No event surfaces in iQualize — Continuity isn't trying *harder*, it just doesn't try at all when the destination device looks "in use".

## The asymmetry (important)

- **iPhone → Mac auto-handoff (destination demands)**: works fine, *anytime*, even with iQualize running. When Mac starts playing audio, Continuity grabs AirPods from iPhone. iPhone yields easily. iQualize then sees `kAudioHardwarePropertyDefaultOutputDevice` change and rebuilds against the new default. This direction has never been broken.
- **Mac → iPhone auto-handoff (source must yield)**: blocked. Mac has the AirPods, iQualize holds them, Continuity has no way to force-yank from a held device. The user has to switch manually (Control Center → AirPods → iPhone).

This is why the user-reported bug only describes one direction.

## What does and doesn't help — empirical results

Tested live with logs from `log stream --predicate 'subsystem == "com.iqualize"' --info`:

### `AVAudioRoutingArbiter.shared.begin(category: .playback)` / `.leave()`
The blessed Apple API for participating in handoff. Adding `begin` around engine start and `leave` around stop had **no observable effect** on handoff. The arbiter governs AVAudioEngine *output participation* but doesn't actually release lower-level device claims.

### `kAudioDevicePropertyDeviceIsAlive` listener on the AirPods subdevice
Fires when the AirPods are actually released — but **only fires when something else (not iQualize) caused the release**, e.g. taking the AirPods out of the case during a phone call. It does **not** fire when Continuity tries-and-fails to move the AirPods because iQualize holds them. Useless as a handoff signal in steady state, but cheap and slightly useful as a safety net.

### `kAudioHardwarePropertyDevices` listener
Fires dozens of times during any Bluetooth state change (each subdevice transition, each property update). Noisy.

**Important finding (confirmed empirically)**: this listener does *not* fire when iPhone *wants* the AirPods while iQualize is holding them. It only fires when the device list actually changes — and the device list doesn't change because iQualize never releases the AirPods, so Continuity's claim attempt fails silently in the AirPods firmware without producing any Mac-side event.

This kills the "event-triggered yield" approach entirely. There is **no Core Audio signal** for "another device is trying to claim our held device". Anything reactive on the Mac side is fundamentally blind to the iPhone's intent.

### `userEnabled` state machine (separates user intent from current engine state)
Real win. Today's code uses `isRunning` as both "user wants EQ" and "audio is currently flowing". Splitting these — `userEnabled` for intent, `isRunning` for current state — lets `handleDeviceChange` restart on default-device change whether or not the engine is currently running. This is what made *manual* device switching reliable (e.g. switching to internal speakers and back via Control Center). It does **not** fix auto-handoff because the device-pinning issue is upstream of `handleDeviceChange`.

### Option C — restructure aggregate so AirPods aren't a subdevice
Move the aggregate's main subdevice from AirPods to built-in audio. Tap captures system audio through the aggregate; AVAudioEngine output stays pinned to AirPods. Result: the aggregate no longer holds AirPods, but the AVAudioEngine output AU does — and *that* claim is sufficient to block handoff on its own. Architectural improvement (cleaner separation of concerns, less weird coupling between tap-capture and output-routing) but **did not unlock auto-handoff** as a standalone fix.

Quality cost: in principle adds one SRC stage between the aggregate's rate and the output device's rate. In practice both are 48 kHz on modern Macs/AirPods, so the SRC is a no-op.

### Idle/silence-based teardown
Detect sustained silence in the ring buffer, then tear down the engine to release device claims. Continuity can move AirPods during the silence. **Not tested** because of clipping concerns at audio resume (~200–400 ms gap) and because the user prefers a non-silence-gated solution.

## The "restart window" — the actual mechanism that does let handoff happen

Empirically: **the only time auto-handoff fires (either direction) while iQualize is running is during the brief 100–300 ms window when iQualize's engine is tearing down + rebuilding for an unrelated reason** (a default-device change, the app restarting, etc).

During that window, the AVAudioEngine output AU is not running on the AirPods. Continuity grabs the moment.

This is the key insight that came out of user testing. It tells us that the *event* we need to manufacture isn't "silence" — it's "briefly stop running the output AU on the AirPods, then resume". A short interruption of the output AU is enough.

## Source-backed insight: canonical CATap pattern (Flavor A)

The reference implementations (AudioCap, SoundPusher, AudioTee) all use a **tap-only aggregate** — the aggregate device contains *only* the process tap via `kAudioAggregateDeviceTapListKey`. **No `SubDeviceList`. No `MainSubDeviceKey`. No `ClockDeviceKey`.** The tap supplies both the input stream and the clock.

Why this matters: a sub-device of a *running* aggregate is non-preemptible by the auto-switch arbiter. Normal shared-mode output streams are preemptible (which is why Music.app works fine — Continuity can yank the AirPods mid-playback). iQualize's bug was specifically that it pinned the AirPods as a committed aggregate sub-device.

Implementation:

```swift
let aggregateDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey:         "iQualize-Aggregate",
    kAudioAggregateDeviceUIDKey:          aggregateUID,
    kAudioAggregateDeviceIsPrivateKey:    true,
    kAudioAggregateDeviceIsStackedKey:    false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true,
         kAudioSubTapUIDKey: tapUUID.uuidString]
    ],
]
```

**Tested empirically (Flavor A alone, with explicit AVAudioEngine output pin still in place): did not fix Mac→iPhone auto-handoff.** The aggregate was no longer the suspect, but something else still held the AirPods.

## Source-backed insight 2: explicit output AU pin (tested next)

`kAudioOutputUnitProperty_CurrentDevice` set explicitly on `AVAudioEngine.outputNode.audioUnit` may make a shared-mode stream non-preemptible too. Music.app and other normal media apps don't do this — they use the system default output. The HAL output unit binds at engine start either way, but "default-device" binding and "explicit-device" binding may carry different metadata that Continuity uses to decide preemptibility.

The combined change (tap-only aggregate + no explicit output AU pin) was the next experiment. **Status: implemented but not user-tested before context reset.** The code in the working tree on `fix/airpods-handoff-yield` reflects this state.

If this combination still doesn't fix handoff, the remaining suspects (in order of likelihood):

1. The HAL output unit's IOProc itself, while running, holds the device in a way that prevents preemption — even when device binding is default and shared-mode is assumed. Would need to inspect what AudioCap-style apps do that's different.
2. CATap muteBehavior `.muted` may have side effects on device claim semantics.
3. Some lifecycle interaction with `kAudioAggregateDeviceTapAutoStartKey: true`.

## Remaining viable approaches (all proactive — no reactive option exists)

Because there's no event we can listen for, any fix has to *proactively* yield the output AU at moments when handoff might be wanted. Three flavors, with trade-offs:

### 1. Silence-based yield (long threshold)

Track ring-buffer peak amplitude. If silent for ≥15–30 s, yield the output AU (`AudioOutputUnitStop` for ~200 ms then `AudioOutputUnitStart`). Resume on next non-silent sample.

- **Pros**: yields are inaudible (we're silent anyway); minimal complexity; covers the most common handoff case (you paused music to take a call on phone).
- **Cons**: doesn't fix Mac→iPhone *during* active playback. Long threshold means user waits 15–30 s before the handoff window opens.

### 2. Periodic yield with audio-aware gating

Every N seconds: if silent → full yield (200 ms); if audio playing → micro-yield (~30 ms, audible click).

- **Pros**: handoff window always available; not gated on silence.
- **Cons**: clicks during music. Probably noticeable. Possibly fixable with crossfade/ramp but that's a real DSP task.

### 3. User-triggered release

Add a menu-bar item / global shortcut: "Release AirPods (5 s)". When triggered, yield for ~5 s so the user can switch to iPhone.

- **Pros**: zero audio quality cost in steady state; no heuristics; predictable.
- **Cons**: still a manual step (better than today: it's *fewer* clicks than navigating Control Center → AirPods → iPhone, and works without leaving the current app).

## Open questions

- Does `AudioOutputUnitStop` alone (without engine.stop()) actually release the device claim enough for Continuity to act? Needs experiment.
- Does the engine survive a stop/start of just its output AU? Or do we have to restart the whole engine?
- Is there a less noisy signal than `kAudioHardwarePropertyDevices` that correlates with handoff attempts? Worth checking `kAudioObjectPropertyOwnedObjects` on the system object.

## Files involved

- `Sources/iQualize/AudioEngine.swift` — where any fix lands
- `Sources/iQualize/CoreAudioHelpers.swift` — Core Audio property reads
- `Sources/iQualize/iQualizeApp.swift` — sleep/wake handling (uses `audioEngine.isRunning`; would also touch `userEnabled` if we revive that refactor)

## 2026-05-28: Empirical proof that the combined fix already applies

After the user reported "the first attempt didn't work" on `fix/airpods-handoff-yield`, we tried to externally inspect iQualize's live aggregate to determine whether the source edit had taken effect at runtime.

**Critical finding about diagnostics**: aggregates created with `kAudioAggregateDeviceIsPrivateKey: true` are process-private. They are invisible to other processes via every public enumeration path tested:

- `kAudioHardwarePropertyDevices` — does not list them.
- `kAudioHardwarePropertyTranslateUIDToDevice` — returns `kAudioObjectUnknown` even with the correct UID.
- `kAudioHardwarePropertyPlugInList` + `kAudioObjectPropertyOwnedObjects` on the CoreAudio HAL plugin — returns the same view as `kAudioHardwarePropertyDevices` (i.e. blind to other processes' private aggregates).

`AggregateDiag_v1.swift` and `AggregateDiag_v2.swift` (both at repo root) are kept as references but their verdicts cannot be trusted for *iQualize's* aggregate when run from another process. They will always report "0 aggregates" regardless of iQualize's actual state.

**The diagnostic that actually works**: dump the aggregate's `FullSubDeviceList` and `TapList` from inside the process, via `os_log`. `AudioEngine.swift` now does this immediately after `AudioHardwareCreateAggregateDevice` succeeds (see `logAggregateState`).

**Empirical readout with the working-tree edit installed** (pid 82977, AirPods as default output):

```
aggregate state: id=155 tapOnly=YES subDevices=(empty) taps=A9BEA664-...
```

The aggregate is tap-only. No hardware sub-devices. No AirPods pin via the aggregate. The diagnosed root cause is fully resolved in the source.

**Conclusion**: none of the four suspects the brief enumerated (stale UID, clock back-door, default-output write, explicit AU binding) explains the user-observed bug. The aggregate's structure at runtime matches the canonical SoundPusher/AudioCap pattern exactly. If Mac→iPhone handoff still fails, the cause is in the "remaining suspects" tail above: the HAL output unit's IOProc on the AirPods (not the aggregate), CATap `muteBehavior: .muted` side effects on device-claim semantics, or `TapAutoStart` lifecycle interaction.

## 2026-05-28: THE FIX — split into a capture helper process

The pivotal experiment: a debug flag (`debugStopEngineKeepTap`) made `start()` immediately `avEngine.stop()` after creating tap+aggregate+IOProc. With that flag on — tap and aggregate alive, AVAudioEngine output stopped — iPhone successfully migrated the AirPods. With the engine running, it did not.

That ruled out the render API itself. We then tried `AVSampleBufferAudioRenderer` instead of `AVAudioEngine` and it changed nothing. The user pointed out the real asymmetry: Spotify mid-playback gets preempted by Continuity, while iQualize never does — and killing iQualize *instantly* frees the AirPods for the iPhone.

The remaining variable: **iQualize was the only process owning both a CATap *and* a render IOProc on the AirPods.** That combination is what coreaudiod treats as non-preemptible "audio infrastructure" instead of a normal media app.

**The fix**: split into two processes.

- `Sources/iQualizeCapture/main.swift` — small helper binary bundled at `iQualize.app/Contents/Helpers/iQualizeCapture`. Owns the CATap + tap-only aggregate + IOProc. Writes captured Float32 samples into a POSIX shared-memory ring buffer it allocates via `shm_open` + `mmap`. Sends a single JSON handshake line to stdout describing the layout. Watches stdin for EOF (parent died) and SIGTERM (parent's normal stop) for clean teardown.
- `Sources/iQualize/CaptureClient.swift` — main app spawns the helper via `Process()`, reads the handshake line with raw `read(2)` on the pipe FD (Foundation's `FileHandle.read(upToCount:)` empirically hung in this configuration), `shm_open`s the same name, `mmap`s the region, exposes a `read(_:count:)` matching the old `AudioRingBuffer` interface so the AVAudioEngine render path is unchanged.
- `Sources/iQualize/AudioEngine.swift` — no longer creates a tap, aggregate, or IOProc. Just builds the AVAudioEngine graph and renders to the system default output. To coreaudiod, this process looks like Spotify.

Empirically confirmed: with this split, mid-playback Mac→iPhone handoff works the same as it does without iQualize. AirPods migrate cleanly when the iPhone starts audio.

### Why this is the only no-driver answer

Every other approach we tried — tap-only aggregate, removing the explicit output-AU pin, `AVAudioRoutingArbiter` with both `.playback` and `.playAndRecord`, switching render to `AVSampleBufferAudioRenderer`, silence-yield, periodic yield — was constrained to a single process and could not break the CATap-owner-equals-renderer linkage. Once the linkage is broken via process split, none of those workarounds is needed.

### Build / sign / lifecycle

- `Package.swift` declares a second executable target `iQualizeCapture`.
- `install.sh` builds both binaries, installs the helper at `Contents/Helpers/iQualizeCapture`, signs it separately with `iQualizeCapture.entitlements`, then re-signs the main bundle.
- Main app sets `Process.terminationHandler` on the helper to detect unexpected exit (sets engine error, stops EQ — user can re-enable).
- Helper auto-cleans its shared memory + tap/aggregate on SIGTERM/SIGINT/SIGHUP, and on stdin EOF (parent death without graceful SIGTERM).

### Killed dead ends

- `AggregateDiag_v1.swift`, `AggregateDiag_v2.swift` — external diagnostic scripts. Both blind to `IsPrivate=true` aggregates regardless of enumeration path. Deleted.
- `Sources/iQualize/AudioRingBuffer.swift` — no longer used; the helper writes directly to mmap'd shared memory. Deleted.
- `sweepLeakedAggregates`, `logAggregateState`, related HAL plugin enumeration helpers in `AudioEngine.swift` — main app no longer creates aggregates, so these are dead. Removed.
- `AVAudioRoutingArbiter` `begin`/`leave` — no observable effect with either category, both before and after the architectural split. Removed.
