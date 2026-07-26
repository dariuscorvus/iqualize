#!/usr/bin/env python3
"""Measure the RMS level (dBFS) of a single test tone in a 16-bit mono WAV.

Goertzel per 1-second block, power-averaged across blocks. Two deliberate
properties:
- 1 s blocks put an integer-Hz tone exactly on a bin (no scalloping), and
  incoherent (power) averaging keeps occasional sub-ms ring-buffer slips in
  the capture path from reading as level loss — a phase jump only degrades
  the one block it lands in. Coherent integration over the whole file would
  punish a single slip by several dB.
- The ~1 Hz-wide detector means background music, speech, or noise on the
  capture doesn't move the reading the way wideband RMS does.

Usage: goertzel.py capture.wav 997
"""
import math
import struct
import sys
import wave

path, freq = sys.argv[1], float(sys.argv[2])
w = wave.open(path)
if w.getsampwidth() != 2 or w.getnchannels() != 1:
    sys.exit("expected 16-bit mono WAV")
n = w.getnframes()
sr = w.getframerate()
x = struct.unpack("<%dh" % n, w.readframes(n))

def block_rms(block, k):
    m = len(block)
    wr = 2.0 * math.pi * k / m
    cw = 2.0 * math.cos(wr)
    s1 = s2 = 0.0
    for v in block:
        s0 = v / 32768.0 + cw * s1 - s2
        s2, s1 = s1, s0
    power = s1 * s1 + s2 * s2 - cw * s1 * s2
    amp = 2.0 * math.sqrt(max(power, 1e-30)) / m
    return amp / math.sqrt(2.0)

blocks = max(1, n // sr)
powers = []
for b in range(blocks):
    block = x[b * sr:(b + 1) * sr]
    k0 = round(freq * len(block) / sr)
    rms = max(block_rms(block, k) for k in range(k0 - 1, k0 + 2))
    powers.append(rms * rms)

mean_rms = math.sqrt(sum(powers) / len(powers))
print(f"{20 * math.log10(max(mean_rms, 1e-15)):.2f}")
