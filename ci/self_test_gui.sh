#!/usr/bin/env bash
# Proves the GUI checks can fail: a black picture and a flat gray one must fail the blank-picture rule while a real one
# passes, and a picture must match itself while the pictures of two different states, or of the same state before and
# after the host turned Wet, must not match.
#
# Usage: ci/self_test_gui.sh <vst3_check> <label>
#   Run it from the repository root on macOS with python3, after ci/run_gui_checks.sh has put the pictures in
#   ci-results/<label>/gui/. Uses GUI_MAX_DIFFERENT_SHARE like ci/run_gui_checks.sh.

tool=$1
pictures=ci-results/$2/gui
max_share=${GUI_MAX_DIFFERENT_SHARE:?set GUI_MAX_DIFFERENT_SHARE, see ci/README.md}
dir=ci-results/self-test-gui
mkdir -p "$dir"
failed=0

expect() {
    want=$1
    what=$2
    shift 2
    "$tool" "$@" >"$dir/last.log" 2>&1
    code=$?
    if { [ "$want" = pass ] && [ $code -eq 0 ]; } || { [ "$want" = fail ] && [ $code -eq 1 ]; }; then
        echo "ok: $what (should $want, exit code $code)"
    else
        echo "NOT OK: $what (should $want, exit code $code)"
        tail -n 30 "$dir/last.log"
        failed=1
    fi
}

# Flat pictures the size of the editor, written with Python's standard library only.
python3 - "$dir" <<'EOF'
import struct
import sys
import zlib


def png(path, rgb, width=611, height=662):
    rows = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


png(sys.argv[1] + "/black.png", (0, 0, 0))
png(sys.argv[1] + "/gray.png", (236, 236, 236))
EOF

expect fail "a black picture" image "$dir/black.png"
expect fail "a flat gray picture" image "$dir/gray.png"
expect pass "a picture of the editor" image "$pictures/default.png"
expect pass "a picture compared with itself" compare "$pictures/default.png" "$pictures/default.png" "$max_share"
expect fail "pictures of two different states" \
    compare "$pictures/default.png" "$pictures/multipoint-curve.png" "$max_share"
expect fail "the same state before and after the host turned Wet" \
    compare "$pictures/multipoint-curve.png" "$pictures/multipoint-curve-wet-0.25.png" "$max_share"

if [ $failed -ne 0 ]; then
    echo "GUI SELF-TEST FAILED: a GUI check did not react the way it should"
    exit 1
fi
echo "GUI SELF-TEST PASSED: the blank-picture rule and the comparison fail on wrong pictures and pass on right ones"
