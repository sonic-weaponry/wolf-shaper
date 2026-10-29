#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Sonic Weaponry
"""The sound null test: how much is left when one render is subtracted from another.

Usage:
  python3 ci/null_test.py [options] <a.wav> <b.wav> [<a.wav> <b.wav>...]
  python3 ci/null_test.py [options] --dirs <folder a> <folder b>
      every WAV in folder a against the file of the same name in folder b
Options:
  --identical      fail unless every pair is bit-identical
  --limit <dBFS>   fail when a residual's peak is above this (for example -100)
  --label <text>   a title for the report

Both files must be 32-bit float WAVs with the same sample rate, channels and length (Wolf Shaper has no latency, so
renders line up sample for sample). Per pair it prints "bit-identical", or the residual: its peak and RMS in dBFS, how
far the peak sits below the louder render's peak, and where and in which channel the biggest difference is. Exit
code 1 when a pair breaks --identical or --limit, or a file is missing or doesn't match its partner; 0 otherwise.
Uses only Python's standard library.
"""

import math
import os
import struct
import sys
from array import array


def read_wav(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("%s is not a WAV file" % path)
    at, fmt = 12, None
    while at + 8 <= len(data):
        chunk, size = data[at:at + 4], struct.unpack_from("<I", data, at + 4)[0]
        body = at + 8
        if chunk == b"fmt ":
            tag, channels, rate = struct.unpack_from("<HHI", data, body)
            bits = struct.unpack_from("<H", data, body + 14)[0]
            if tag == 0xFFFE and size >= 40:
                tag = struct.unpack_from("<H", data, body + 24)[0]
            fmt = (tag, channels, rate, bits)
        elif chunk == b"data":
            if fmt is None or fmt[0] != 3 or fmt[3] != 32:
                raise ValueError("%s is not a 32-bit float WAV file" % path)
            samples = array("f")
            samples.frombytes(data[body:body + size - size % 4])
            if sys.byteorder != "little":
                samples.byteswap()
            return fmt[2], fmt[1], samples, data[body:body + size]
        at = body + size + (size & 1)
    raise ValueError("%s has no data chunk" % path)


def dbfs(level):
    return "-inf" if level <= 0 else "%.1f" % (20.0 * math.log10(level))


def compare(path_a, path_b):
    """Returns (residual peak or None when bit-identical, report line, problem or None)."""
    rate_a, channels_a, a, raw_a = read_wav(path_a)
    rate_b, channels_b, b, raw_b = read_wav(path_b)
    if (rate_a, channels_a, len(a)) != (rate_b, channels_b, len(b)):
        return None, "", "%s is %d Hz, %d channel(s), %d samples; %s is %d Hz, %d channel(s), %d samples" % (
            path_a, rate_a, channels_a, len(a), path_b, rate_b, channels_b, len(b))
    if raw_a == raw_b:
        return None, "bit-identical (%d frames)" % (len(a) // channels_a), None
    peak = sum_squares = peak_signal = 0.0
    where = 0
    for i in range(len(a)):
        x, y = a[i], b[i]
        if math.isnan(x) or math.isnan(y) or math.isinf(x) or math.isinf(y):
            return None, "", "NaN or infinity at sample %d" % i
        d = abs(x - y)
        sum_squares += d * d
        if d > peak:
            peak, where = d, i
        peak_signal = max(peak_signal, abs(x), abs(y))
    rms = math.sqrt(sum_squares / len(a))
    below = 20.0 * math.log10(peak_signal / peak) if peak_signal > 0 else 0.0
    line = "residual peak %s dBFS, RMS %s dBFS, %.1f dB below the signal's peak; biggest at %.4f s, %s" % (
        dbfs(peak), dbfs(rms), below, (where // channels_a) / rate_a,
        ("left", "right")[where % channels_a] if channels_a == 2 else "mono")
    return peak, line, None


def main(argv):
    identical, limit, label, use_dirs, paths = False, None, None, False, []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--identical":
            identical = True
        elif arg == "--limit":
            i += 1
            limit = float(argv[i])
        elif arg == "--label":
            i += 1
            label = argv[i]
        elif arg == "--dirs":
            use_dirs = True
        else:
            paths.append(arg)
        i += 1

    pairs, problems = [], []
    if use_dirs:
        if len(paths) != 2:
            print(__doc__)
            return 2
        names = sorted(n for n in os.listdir(paths[0]) if n.lower().endswith(".wav"))
        for name in names:
            other = os.path.join(paths[1], name)
            if os.path.exists(other):
                pairs.append((os.path.join(paths[0], name), other, name))
            else:
                problems.append("%s: missing in %s" % (name, paths[1]))
        if not names:
            problems.append("no WAV files in %s" % paths[0])
    else:
        if len(paths) < 2 or len(paths) % 2:
            print(__doc__)
            return 2
        for a, b in zip(paths[0::2], paths[1::2]):
            pairs.append((a, b, "%s vs %s" % (os.path.basename(a), os.path.basename(b))))

    if label:
        print("NULL TEST %s" % label)
    worst = None
    identical_count = 0
    for a, b, name in pairs:
        try:
            peak, line, problem = compare(a, b)
        except (OSError, ValueError) as error:
            peak, line, problem = None, "", str(error)
        if problem:
            problems.append("%s: %s" % (name, problem))
            print("  %s: PROBLEM %s" % (name, problem))
            continue
        print("  %s: %s" % (name, line))
        if peak is None:
            identical_count += 1
            continue
        worst = peak if worst is None else max(worst, peak)
        if identical:
            problems.append("%s: not bit-identical" % name)
        elif limit is not None and 20.0 * math.log10(peak) > limit:
            problems.append("%s: residual %s dBFS is above %g dBFS" % (name, dbfs(peak), limit))

    summary = "%d pairs, %d bit-identical, worst residual %s dBFS" % (
        len(pairs), identical_count, dbfs(worst) if worst is not None else "-inf")
    for problem in problems:
        print("  FAIL %s" % problem)
    print("NULL TEST %s: %s" % ("FAIL" if problems else "PASS", summary))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
