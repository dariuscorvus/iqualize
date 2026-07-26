#!/bin/bash
# End-to-end verification of the #131 call-exclusion fix.
#
# While a process runs a voice session (holds the mic), macOS ducks all
# "other audio" on the output device but exempts the session owner's own
# stream. Without the fix, iQualize taps + mutes the call app and re-renders
# its voice as ordinary app audio — which the OS then ducks (~18 dB measured),
# making calls very quiet. The fix excludes mic-holding processes from the
# tap so their audio plays natively.
#
# vpio_tone plays a tone through kAudioUnitSubType_VoiceProcessingIO — the
# same AU FaceTime/WhatsApp/the phone relay use — so no real call is needed.
#
#   B: app off, VPIO tone -> native voice-session level
#   T: app on,  VPIO tone -> must match B within ~1.5 dB (fix working)
#      Without the fix T reads ~18 dB below B.
#
# Needs: brew install sox blackhole-2ch. The first capture triggers a macOS
# microphone-permission prompt. Takes over the default output for ~30 s and
# restarts iQualize; restores both on exit.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${1:-BlackHole 2ch}"
APP=/Applications/iQualize.app

command -v sox >/dev/null || { echo "FAIL: sox not installed (brew install sox)"; exit 1; }
[ -x "$DIR/setoutput" ] && [ "$DIR/setoutput" -nt "$DIR/setoutput.swift" ] \
    || swiftc -O -framework CoreAudio -o "$DIR/setoutput" "$DIR/setoutput.swift" || exit 1
[ -x "$DIR/vpio_tone" ] && [ "$DIR/vpio_tone" -nt "$DIR/vpio_tone.swift" ] \
    || swiftc -O -framework AudioToolbox -framework CoreAudio -o "$DIR/vpio_tone" "$DIR/vpio_tone.swift" || exit 1
"$DIR/setoutput" 2>/dev/null | grep -qi "${DEVICE}" \
    || { echo "FAIL: output device \"$DEVICE\" not found (brew install --cask blackhole-2ch)"; exit 1; }

rms() { # capture 4s from $DEVICE (ch 1+2), measure the 997 Hz test tone via
        # a Goertzel bin — sub-Hz selectivity, so background playback on the
        # machine can't skew the reading
    sox -q -t coreaudio "$DEVICE" -b 16 "$DIR/.cap.wav" trim 0 4 remix 1,2 2>/dev/null
    python3 "$DIR/goertzel.py" "$DIR/.cap.wav" 997
}

measure_vpio() { # start VPIO tone, wait for the 1s exclusion poll, measure
    "$DIR/vpio_tone" 12 -20 >/dev/null & local p=$!
    sleep 2.5
    rms
    wait $p 2>/dev/null
}

PREV_OUTPUT=$("$DIR/setoutput" --current)
restore() {
    "$DIR/setoutput" "$PREV_OUTPUT" >/dev/null 2>&1
    pgrep -x iQualize >/dev/null || open "$APP"
}
trap restore EXIT

echo "test device: $DEVICE (restoring $PREV_OUTPUT on exit)"
"$DIR/setoutput" "$DEVICE" >/dev/null || exit 1

# Wait out the dying helper's mute-tap, then for the fresh one to come up.
pkill -x iQualize
for _ in $(seq 1 25); do pgrep -x iQualizeCapture >/dev/null || break; sleep 0.2; done
sleep 0.5
B=$(measure_vpio)
echo "B VPIO tone, app off: ${B} dB"

open "$APP"
for _ in $(seq 1 25); do pgrep -x iQualizeCapture >/dev/null && break; sleep 0.2; done
pgrep -x iQualize >/dev/null || { echo "FAIL: iQualize did not start"; exit 1; }
sleep 2
T=$(measure_vpio)
echo "T VPIO tone, app on:  ${T} dB"

DELTA=$(echo "$T $B" | awk '{printf "%+.2f", $1 - $2}')
echo "delta:                ${DELTA} dB"
echo "$DELTA" | awk '{d=$1; if (d<0) d=-d; exit !(d<=1.5)}' \
    && echo "PASS: voice-session audio plays at native level with iQualize running" \
    || echo "FAIL: voice-session audio deviates from native level (ducked through the tap?)"
