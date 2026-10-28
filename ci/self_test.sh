#!/usr/bin/env bash
# Proves the checks can fail. Each check is given deliberately wrong frozen values and must fail, and the same values
# untouched must pass, so a green run can't mean "checked nothing".
#
# Usage: ci/self_test.sh <vst3_check> <bundle>   (from the repository root, on Linux with python3)

tool=$1
bundle=$2
dir=ci-results/self-test
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

# Makes sure a tampered copy really differs from its original, so a broken edit can't fake a pass.
differs() {
    if cmp -s "$1" "$2"; then
        echo "NOT OK: the tampered copy $2 is identical to $1"
        failed=1
    fi
}

# Class IDs: Linux ours with the Windows component ID instead of its own.
expect pass "ids with the frozen table" ids "$bundle" ours ci/frozen/class-ids.txt
sed -E 's/^(linux[[:space:]]+ours[[:space:]]+component[[:space:]]+)[0-9A-F]+/\1445046206173636C7073577300000000/' \
    ci/frozen/class-ids.txt >"$dir/class-ids-wrong.txt"
differs ci/frozen/class-ids.txt "$dir/class-ids-wrong.txt"
expect fail "ids with a wrong component ID" ids "$bundle" ours "$dir/class-ids-wrong.txt"

# Parameters: this build's own table must pass, the same table with one parameter renamed must fail.
"$tool" params "$bundle" "$dir/no-such-file.json" "$dir/parameters.json" >/dev/null 2>&1
expect pass "params against this build's own table" params "$bundle" "$dir/parameters.json"
sed 's/"title": "Wet"/"title": "Wet 2"/' "$dir/parameters.json" >"$dir/parameters-wrong.json"
differs "$dir/parameters.json" "$dir/parameters-wrong.json"
expect fail "params with a renamed parameter" params "$bundle" "$dir/parameters-wrong.json"

# States: the same "wet" value written with one more digit ("0.5" as "0.50") loads fine but doesn't save back the same.
expect pass "states with an untouched test state" states "$bundle" ci/frozen/states/warp-3.vst3state
python3 - ci/frozen/states/warp-3.vst3state "$dir/warp-3-wrong.vst3state" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
start = data.index(b"\x00wet\x00") + len(b"\x00wet\x00")
end = data.index(b"\x00", start)
open(sys.argv[2], "wb").write(data[:end] + b"0" + data[end:])
EOF
differs ci/frozen/states/warp-3.vst3state "$dir/warp-3-wrong.vst3state"
expect fail "states with a value v1.0.2 would write differently" states "$bundle" "$dir/warp-3-wrong.vst3state"

# Instance: this build's own table must pass, the same table with the plugin renamed must fail.
"$tool" instance "$bundle" "$dir/no-such-file.json" "$dir/plugin-info.json" >/dev/null 2>&1
expect pass "instance against this build's own table" instance "$bundle" "$dir/plugin-info.json"
sed 's/"name": "Wolf Shaper"/"name": "Wolf Shaper 2"/' "$dir/plugin-info.json" >"$dir/plugin-info-wrong.json"
differs "$dir/plugin-info.json" "$dir/plugin-info-wrong.json"
expect fail "instance with a renamed plugin" instance "$bundle" "$dir/plugin-info-wrong.json"

if [ $failed -ne 0 ]; then
    echo "SELF-TEST FAILED: a check did not react the way it should"
    exit 1
fi
echo "SELF-TEST PASSED: every check fails on wrong frozen values and passes on the right ones"
