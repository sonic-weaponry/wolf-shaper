#!/usr/bin/env python3
# Writes the public test states in ci/frozen/states/. They are made for the CI checks, not taken from anyone's
# projects, and each file is exactly what Wolf Shaper v1.0.2 (with DPF a4c83bfd) saves for those settings:
#   - DPF's VST3 state layout, NUL-separated: "__dpf_state_begin__", "graph", <curve>, "__dpf_state_end__",
#     "__dpf_parameters_begin__", then each saved parameter's symbol and value in parameter order,
#     "__dpf_parameters_end__", the byte 0xFE, and a final NUL.
#   - Decimal parameters as DPF writes a float (String(float): "%.12g" of the 32-bit value), integer ones as integers.
#   - Curve points as Wolf Shaper writes them (src/Structures/src/Graph.cpp, Graph::serialize): "x,y,tension,type;",
#     with x, y and tension in its hex float form (src/Utils/src/Mathf.cpp, toHexFloat). Type 0 is a single curve,
#     1 stairs, 2 wave; tension runs from -100 to 100.
# The CI state check proves it: the official v1.0.2 release must load each file and save it back byte for byte.
#
# Usage: python3 ci/make_test_states.py   (overwrites ci/frozen/states/)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Sonic Weaponry

import os
import struct

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "frozen", "states")

# DPF reads a state in chunks of 511 bytes, so one test state has to be longer than that.
DPF_READ_CHUNK = 511

# The 10 saved parameters in v1.0.2's order (src/WolfShaperPlugin.cpp, initParameter) and whether DPF saves them as
# integers (kParameterIsInteger). The output parameter "out" isn't saved.
PARAMETERS = [
    ("pregain", False),
    ("wet", False),
    ("postgain", False),
    ("removedc", True),
    ("oversample", True),
    ("bipolarmode", True),
    ("warptype", True),
    ("warpamount", False),
    ("vwarptype", True),
    ("vwarpamount", False),
]

DEFAULTS = {
    "pregain": 1.0,
    "wet": 1.0,
    "postgain": 1.0,
    "removedc": 1,
    "oversample": 0,
    "bipolarmode": 0,
    "warptype": 0,
    "warpamount": 0.0,
    "vwarptype": 0,
    "vwarpamount": 0.0,
}


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def dpf_float(value):
    """A decimal parameter as DPF saves it: "%.12g" of the 32-bit float."""
    return "%.12g" % f32(value)


def wolf_hex(value):
    """A curve number as Wolf Shaper's toHexFloat writes the 32-bit value: 0x0p+0, 0x1p-1, 0x1.8p-1, -0x1.9p+5."""
    v = f32(value)
    if v == 0.0:
        return "0x0p+0"
    mantissa, exponent = v.hex().split("p")  # e.g. "-0x1.9000000000000", "+5"
    if "." in mantissa:
        mantissa = mantissa.rstrip("0").rstrip(".")
    return mantissa + "p" + exponent


def curve(points):
    return "".join(
        "%s,%s,%s,%d;" % (wolf_hex(x), wolf_hex(y), wolf_hex(tension), kind) for x, y, tension, kind in points
    )


def state(points, values):
    tokens = ["__dpf_state_begin__", "graph", curve(points), "__dpf_state_end__", "__dpf_parameters_begin__"]
    for symbol, is_integer in PARAMETERS:
        value = values[symbol]
        tokens += [symbol, str(int(value)) if is_integer else dpf_float(value)]
    tokens += ["__dpf_parameters_end__", "\xfe", ""]
    return "\0".join(tokens).encode("latin-1")


DEFAULT_CURVE = [(0.0, 0.0, 0.0, 0), (1.0, 1.0, 0.0, 0)]

# Nine points with the kind of coordinates the editor produces (six hex digits), every curve type, tensions out to
# both ends, and every knob away from its default.
MULTIPOINT_CURVE = [
    (0.0, 0.0, 0.0, 0),
    (0.0912, 0.3321, 29.0, 0),
    (0.2188, 0.1187, -47.5, 1),
    (0.3407, 0.6642, 100.0, 2),
    (0.4999, 0.5, -100.0, 0),
    (0.6123, 0.8813, 12.25, 1),
    (0.7777, 0.4402, 0.5, 2),
    (0.9031, 0.9585, -3.75, 0),
    (1.0, 1.0, 0.0, 0),
]
MULTIPOINT_VALUES = {
    "pregain": 170 / 127,
    "wet": 101 / 127,
    "postgain": 151 / 300,
    "removedc": 0,
    "oversample": 2,
    "bipolarmode": 1,
    "warptype": 5,
    "warpamount": 27 / 127,
    "vwarptype": 4,
    "vwarpamount": 5 / 300,
}


def warp_state(i):
    """warp-0 to warp-6: together they cover every H and V warp type, every oversample setting, bipolar and DC removal
    on and off, and the ends of every range."""
    points = [(0.0, 0.0, 0.0, 0), (0.125 + i * 0.0625, 0.75 - i * 0.0625, -100.0 + i * 33.25, i % 3)]
    if i % 2 == 1:
        points.append((0.8, 0.2 + 0.05 * i, 50.0 - 10.0 * i, (i + 1) % 3))
    points.append((1.0, 1.0, 0.0, 0))
    values = {
        "pregain": 2 * i / 6,
        "wet": 1 - i / 6,
        "postgain": (i + 1) / 7,
        "removedc": (i + 1) % 2,
        "oversample": i % 5,
        "bipolarmode": i % 2,
        "warptype": i,
        "warpamount": i / 6,
        "vwarptype": (i + 3) % 7,
        "vwarpamount": (6 - i) / 6,
    }
    return points, values


def main():
    states = {
        "default.vst3state": state(DEFAULT_CURVE, DEFAULTS),
        "multipoint-curve.vst3state": state(MULTIPOINT_CURVE, MULTIPOINT_VALUES),
    }
    for i in range(7):
        states["warp-%d.vst3state" % i] = state(*warp_state(i))
    assert len(states["multipoint-curve.vst3state"]) > DPF_READ_CHUNK, "the multipoint state must cross a read chunk"

    os.makedirs(OUT, exist_ok=True)
    for name, data in sorted(states.items()):
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        print("%-28s %4d bytes" % (name, len(data)))


if __name__ == "__main__":
    main()
