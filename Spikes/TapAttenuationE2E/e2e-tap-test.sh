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
# Takes over the default output for ~20 s and restarts iQualize; restores
# both on exit.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${1:-BlackHole 16ch}"
SINE="$DIR/sine997.wav"
APP=/Applications/iQualize.app

command -v sox >/dev/null || { echo "FAIL: sox not installed (brew install sox)"; exit 1; }
[ -x "$DIR/setoutput" ] && [ "$DIR/setoutput" -nt "$DIR/setoutput.swift" ] \
    || swiftc -O -framework CoreAudio -o "$DIR/setoutput" "$DIR/setoutput.swift" || exit 1
[ -f "$SINE" ] || python3 "$DIR/gen_sine.py" "$SINE" || exit 1
"$DIR/setoutput" 2>/dev/null | grep -qi "${DEVICE}" \
    || { echo "FAIL: output device \"$DEVICE\" not found (brew install --cask blackhole-16ch)"; exit 1; }

rms() { # capture 4s from $DEVICE (ch 1+2), measure the 997 Hz test tone via
        # a Goertzel bin — sub-Hz selectivity, so background playback on the
        # machine can't skew the reading
    sox -q -t coreaudio "$DEVICE" -b 16 "$DIR/.cap.wav" trim 0 4 remix 1,2 2>/dev/null
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

# Tolerance 3 dB: the capture pipeline's ring buffer occasionally slips a
# sub-ms chunk (clock drift between the tap aggregate and the render device),
# which adds up to ~±2 dB of run-to-run jitter on this measurement — verified
# present on builds before and after #131. Every real failure mode this test
# guards against (missed stereo-pair step, lost compensation, call ducking)
# is 6 dB or more.
DELTA=$(echo "$THROUGH $BASELINE" | awk '{printf "%+.2f", $1 - $2}')
echo "delta:                      ${DELTA} dB"
echo "$DELTA" | awk '{d=$1; if (d<0) d=-d; exit !(d<=3.0)}' \
    && echo "PASS: unity within 3 dB — OS attenuation exists and is fully compensated" \
    || echo "FAIL: not unity — see delta (positive = over-boost, negative = under-compensation)"
