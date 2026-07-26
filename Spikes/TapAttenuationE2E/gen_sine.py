#!/usr/bin/env python3
"""Generate the e2e test tone: 997 Hz stereo sine at -30 dBFS, 48 kHz, 8 s.

997 Hz is the broadcast-measurement prime: it sits between musical pitches
(B5 = 987.8, C6 = 1046.5), so background music never lands on the
measurement bin.

-30 dBFS leaves 18 dB of headroom, so even a wrongly-uncompensated x8 boost
(16ch device) lands at -12 dBFS without clipping — every failure mode stays
measurable instead of flat-topping.
"""
import math
import struct
import sys
import wave

SR = 48000
SECONDS = 8
FREQ = 997.0
AMP_DB = -30.0

amp = 10 ** (AMP_DB / 20)
path = sys.argv[1] if len(sys.argv) > 1 else "sine.wav"
if len(sys.argv) > 2:
    SECONDS = int(sys.argv[2])

w = wave.open(path, "w")
w.setnchannels(2)
w.setsampwidth(2)
w.setframerate(SR)
frames = bytearray()
for i in range(SR * SECONDS):
    s = int(amp * 32767 * math.sin(2 * math.pi * FREQ * i / SR))
    frames += struct.pack("<hh", s, s)
w.writeframes(bytes(frames))
w.close()
print(f"{path}: {SECONDS}s {FREQ:.0f} Hz sine at {AMP_DB} dBFS, {SR} Hz stereo")
