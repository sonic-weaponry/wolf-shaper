#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Sonic Weaponry
"""Writes the test signal of the sound null test: one mono 32-bit float WAV per sample rate.

Usage: python3 ci/make_test_signal.py <folder>
  writes <folder>/test-signal-44100.wav and <folder>/test-signal-48000.wav

The same file goes through every build being compared (ci/README.md, "The sound"), so it only has to be the same
everywhere: it is computed in double precision from fixed formulas and a fixed noise seed, and ci/frozen/test-signal.sha256
pins the result. What's in it, in order (8.175 s):
  0.000 s  log sine sweep, 20 Hz to 20 kHz, -6 dBFS peak, 3 s, 10 ms fades
  3.000 s  silence, 0.25 s
  3.250 s  110 Hz sine stepped through -40, -24, -12, -6, -3, 0 and +3 dBFS, 0.4 s per step, 5 ms ramps between steps
           (above 0 dBFS the input leaves the curve's range, which Wolf Shaper handles separately)
  6.050 s  silence, 0.25 s
  6.300 s  noise bursts of 0.25 s with 0.125 s of silence between them: white at -18, -6 and 0 dBFS peak, pink at
           -12 dBFS peak, 2 ms fades
  7.675 s  silence, 0.5 s (lets the oversampling filters and the DC remover ring out)
Uses only Python's standard library.
"""

import math
import os
import struct
import sys
from array import array

RATES = (44100, 48000)


def db(level):
    return 10.0 ** (level / 20.0)


class Noise:
    """xorshift64*: the same numbers on every machine and Python version."""

    def __init__(self, seed):
        self.state = seed

    def uniform(self):
        x = self.state
        x ^= x >> 12
        x ^= (x << 25) & 0xFFFFFFFFFFFFFFFF
        x ^= x >> 27
        self.state = x
        value = (x * 0x2545F4914F6CDD1D) & 0xFFFFFFFFFFFFFFFF
        return (value >> 11) * (2.0 / 9007199254740992.0) - 1.0  # [-1, 1)


def fade(i, count, fade_samples):
    """A raised-cosine fade in at the start and out at the end of a segment of count samples."""
    if fade_samples <= 0:
        return 1.0
    edge = min(i, count - 1 - i)
    if edge >= fade_samples:
        return 1.0
    return 0.5 - 0.5 * math.cos(math.pi * edge / fade_samples)


def silence(rate, seconds):
    return [0.0] * int(round(rate * seconds))


def sweep(rate, seconds=3.0, f1=20.0, f2=20000.0, level=-6.0):
    count = int(round(rate * seconds))
    k = math.log(f2 / f1)
    fades = int(round(rate * 0.010))
    out = []
    for i in range(count):
        t = i / rate
        phase = 2.0 * math.pi * f1 * seconds / k * (math.exp(t / seconds * k) - 1.0)
        out.append(db(level) * fade(i, count, fades) * math.sin(phase))
    return out


def stepped_sine(rate, frequency=110.0, levels=(-40, -24, -12, -6, -3, 0, 3), step=0.4, ramp=0.005):
    per_step = int(round(rate * step))
    ramp_samples = int(round(rate * ramp))
    count = per_step * len(levels)
    fades = ramp_samples
    out = []
    for i in range(count):
        n = i // per_step
        into = i - n * per_step
        amplitude = db(levels[n])
        if n > 0 and into < ramp_samples:
            # Linear ramp from the previous step's level, so a step doesn't click.
            previous = db(levels[n - 1])
            amplitude = previous + (amplitude - previous) * into / ramp_samples
        out.append(amplitude * fade(i, count, fades) * math.sin(2.0 * math.pi * frequency * i / rate))
    return out


def noise_bursts(rate, burst=0.25, gap=0.125):
    noise = Noise(0x5357574F4C46)
    count = int(round(rate * burst))
    fades = int(round(rate * 0.002))
    out = []
    for n, (kind, level) in enumerate((("white", -18), ("white", -6), ("white", 0), ("pink", -12))):
        if n > 0:
            out += silence(rate, gap)
        raw = []
        b0 = b1 = b2 = 0.0
        for i in range(count):
            white = noise.uniform()
            if kind == "pink":
                # Paul Kellet's economy pink filter.
                b0 = 0.99765 * b0 + white * 0.0990460
                b1 = 0.96300 * b1 + white * 0.2965164
                b2 = 0.57000 * b2 + white * 1.0526913
                raw.append(b0 + b1 + b2 + white * 0.1848)
            else:
                raw.append(white)
        peak = max(abs(v) for v in raw)
        out += [db(level) * fade(i, count, fades) * v / peak for i, v in enumerate(raw)]
    return out


def signal(rate):
    return (sweep(rate) + silence(rate, 0.25) + stepped_sine(rate) + silence(rate, 0.25) + noise_bursts(rate)
            + silence(rate, 0.5))


def write_wav(path, rate, samples):
    data = array("f", samples)  # rounds each double to the nearest float
    if sys.byteorder != "little":
        data.byteswap()
    payload = data.tobytes()
    fmt = struct.pack("<HHIIHHH", 3, 1, rate, rate * 4, 4, 32, 0)
    fact = struct.pack("<I", len(samples))
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"fact" + struct.pack("<I", 4) + fact
    body += b"data" + struct.pack("<I", len(payload)) + payload
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    for rate in RATES:
        samples = signal(rate)
        path = os.path.join(folder, "test-signal-%d.wav" % rate)
        write_wav(path, rate, samples)
        print("%s: %d samples, %.3f s" % (path, len(samples), len(samples) / rate))
    return 0


if __name__ == "__main__":
    sys.exit(main())
