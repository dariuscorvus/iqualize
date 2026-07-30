#!/bin/bash
# End-to-end verification of the #107 tap headroom compensation.
#
# Core Audio attenuates a stereo mixdown tap by the output device's
# stereo-pair count (Apple Developer Forums thread 806799); iQualize
# compensates by the same factor (GainPolicy.tapHeadroomCompensation).
# This measures the real OS behavior — rerun after macOS updates: if Apple
# ever removes the attenuation, the compensation over-boosts by the pair
# count and this test catches it before users hear clipping.
#
# Routes system audio to BlackHole (a virtual loopback device), plays a
# -30 dBFS sine, and records what actually arrives at the device:
#   baseline  — iQualize killed: afplay reaches BlackHole directly
#   iqualize  — iQualize running (Bypass on): the tap mutes afplay's direct
#               feed, so the recording is exactly what iQualize renders
# If the attenuation exists and the compensation restores it, baseline and
# iqualize RMS match (within ~1 dB).
#   iqualize ~= baseline        -> unity: attenuation exists, compensation correct
#   iqualize ~= baseline + N dB -> over-boost: less OS attenuation than compensated
#   iqualize ~= baseline - N dB -> under-compensation
#
# Needs: brew install sox blackhole-16ch (blackhole-2ch for the stereo
# control run: ./e2e-tap-test.sh "BlackHole 2ch"). First run triggers a
# macOS microphone-permission prompt — deny it and the capture is silent.
# Takes over the default output for ~40 s and restarts iQualize; restores
# both on exit.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${1:-BlackHole 16ch}"
# 16 s tone: the measurement window is the LAST 4 s of a 12 s capture. afplay
# and sox are themselves new Core Audio processes, and iQualize restarts its
# tap when the process list grows (#87, 2 s poll) — so the first ~4 s of every
# through-iQualize capture contain up to two full tap restarts, each splicing
# ~100 ms of silence. Block averaging shrugged that off; the #133 coherence
# check cannot. Measuring the tail keeps the tooling's own restarts out of
# the window.
SINE="$DIR/sine997-16s.wav"
APP=/Applications/iQualize.app

command -v sox >/dev/null || { echo "FAIL: sox not installed (brew install sox)"; exit 1; }
[ -x "$DIR/setoutput" ] && [ "$DIR/setoutput" -nt "$DIR/setoutput.swift" ] \
    || swiftc -O -framework CoreAudio -o "$DIR/setoutput" "$DIR/setoutput.swift" || exit 1
[ -f "$SINE" ] || python3 "$DIR/gen_sine.py" "$SINE" 16 || exit 1
"$DIR/setoutput" 2>/dev/null | grep -qi "${DEVICE}" \
    || { echo "FAIL: output device \"$DEVICE\" not found (brew install --cask blackhole-16ch)"; exit 1; }

rms() { # capture 12 s from $DEVICE (ch 1+2), keep the last 4 s (see the SINE
        # comment above), measure the 997 Hz test tone via a Goertzel bin —
        # sub-Hz selectivity, so background playback can't skew the reading
    sox -q -t coreaudio "$DEVICE" -b 16 "$DIR/.cap-full.wav" trim 0 12 remix 1,2 2>/dev/null
    sox -q "$DIR/.cap-full.wav" "$DIR/.cap.wav" trim -4 2>/dev/null
    python3 "$DIR/goertzel.py" "$DIR/.cap.wav" 997
}

play_and_measure() {
    afplay "$SINE" &
    local afpid=$!
    sleep 1
    local level
    level=$(rms)
    kill $afpid 2>/dev/null
    wait $afpid 2>/dev/null
    echo "$level"
}

PREV_OUTPUT=$("$DIR/setoutput" --current)
restore() {
    "$DIR/setoutput" "$PREV_OUTPUT" >/dev/null 2>&1
    pgrep -x iQualize >/dev/null || open "$APP"
}
trap restore EXIT

echo "test device: $DEVICE"
echo "restoring output to: $PREV_OUTPUT (on exit)"
"$DIR/setoutput" "$DEVICE" >/dev/null || exit 1

# --- baseline: no iQualize in the path ---
# Wait for the capture helper to actually exit: its global mute-tap lingers
# through teardown and silences the baseline if we race it.
pkill -x iQualize
for _ in $(seq 1 25); do pgrep -x iQualizeCapture >/dev/null || break; sleep 0.2; done
sleep 0.5
BASELINE=$(play_and_measure)
echo "baseline RMS (app off):     ${BASELINE} dB"

# --- through iQualize, Bypass on ---
open "$APP"
for _ in $(seq 1 25); do pgrep -x iQualizeCapture >/dev/null && break; sleep 0.2; done
pgrep -x iQualize >/dev/null || { echo "FAIL: iQualize did not start"; exit 1; }
"$APP/Contents/Resources/bin/iqualize" bypass on >/dev/null 2>&1
sleep 1.5
THROUGH=$(play_and_measure)
echo "iQualize RMS (bypass on):   ${THROUGH} dB"

# Tolerance 1 dB. It was 3 dB to absorb ~±2 dB of run-to-run jitter that
# turned out to be mid-window tap restarts (see the SINE comment) — with the
# measurement window past the restarts and the ring drift-compensated (#133)
# the reading is stable, and every real failure mode this test guards against
# (missed stereo-pair step, lost compensation, call ducking) is 6 dB or more.
DELTA=$(echo "$THROUGH $BASELINE" | awk '{printf "%+.2f", $1 - $2}')
echo "delta:                      ${DELTA} dB"
echo "$DELTA" | awk '{d=$1; if (d<0) d=-d; exit !(d<=1.0)}' \
    && echo "PASS: unity within 1 dB — OS attenuation exists and is fully compensated" \
    || echo "FAIL: not unity — see delta (positive = over-boost, negative = under-compensation)"

# --- phase coherence through the capture ring (#133) ---
# .cap.wav still holds the iQualize-path capture. Coherent whole-window
# integration must agree with the block-averaged reading: any phase break in
# the window — a ring slip under clock drift, a tap restart — drags the
# coherent number down while barely moving the block average.
COHERENT=$(python3 "$DIR/goertzel.py" "$DIR/.cap.wav" 997 --coherent)
CDELTA=$(echo "$THROUGH $COHERENT" | awk '{printf "%+.2f", $1 - $2}')
echo "coherent RMS (same capture): ${COHERENT} dB (block - coherent = ${CDELTA} dB)"
echo "$CDELTA" | awk '{d=$1; if (d<0) d=-d; exit !(d<=0.5)}' \
    && echo "PASS: phase-coherent — no ring slips in the capture path" \
    || echo "FAIL: coherent reading diverges — the capture ring is slipping (#133 regression)"
