#!/usr/bin/env bash
# Opens Wolf Shaper's editor on macOS the way a host does with the public test states, and checks what it drew (its
# OpenGL buffer; see ci/README.md for why not the window photo): no picture may be blank, and when a reference label is
# given, each must match the picture that build drew of the same state on this machine (in CI: the official v1.0.2,
# so it runs first). A photo of the window is saved next to each picture, for the record.
#
# Usage: ci/run_gui_checks.sh <vst3_check> <bundle> <label> <reference label or -> [<launcher>...]
#   <launcher> is an optional command to run the check tool through, e.g. "arch -x86_64" for the Intel slice.
#   GUI_MAX_DIFFERENT_SHARE: how much of a picture may differ from the reference's (see ci/README.md).
#
# Run it from the repository root. Pictures, photos and logs go to ci-results/<label>/gui/, a results table to
# $GITHUB_STEP_SUMMARY when that is set. Exits 1 if any check failed. As in ci/run_checks.sh, a check also fails when
# the plugin prints a DPF assertion or warning. DPF's "Failed to create NanoVG context, expect a black screen" is one.

tool=$1
bundle=$2
label=$3
reference=$4
shift 4
launcher=("$@")

max_share=${GUI_MAX_DIFFERENT_SHARE:?set GUI_MAX_DIFFERENT_SHARE, see ci/README.md}
states=ci/frozen/states
out="ci-results/$label/gui"
mkdir -p "$out"
failed=0
table="| Check | Result | Detail |
|---|---|---|"

run_check() {
    name=$1
    shift
    log="$out/$name.log"
    err="$out/$name.stderr.log"
    "$@" >"$log" 2>"$err"
    code=$?

    result_line=$(grep '^RESULT ' "$log" | tail -n 1)
    if [ $code -eq 0 ] && [ -n "$result_line" ]; then
        result=PASS
    else
        result=FAIL
    fi
    detail=$(echo "$result_line" | sed -E 's/^RESULT [a-z]+ (PASS|FAIL) //')
    if [ -z "$result_line" ]; then
        detail="no RESULT line (exit code $code): the check crashed or could not start"
    fi
    dpf_lines=$(grep -e 'assertion failure' -e 'DPF warning' "$err" | head -n 3)
    if [ -n "$dpf_lines" ]; then
        result=FAIL
        detail="$detail; DPF printed: $(echo "$dpf_lines" | tr '\n' ' ')"
    fi

    echo "::group::$label $name: $result"
    cat "$log"
    if [ -s "$err" ]; then
        echo "--- stderr"
        cat "$err"
    fi
    echo "::endgroup::"
    echo "$label $name: $result $detail"

    [ "$result" = PASS ] || failed=1
    table="$table
| $name | $result | $(echo "$detail" | sed 's/|/\\|/g') |"
}

# The default state, then the rack-like nine-point curve, pictured again after the host turns Wet down to 0.25 with the
# window open, as a rack's macro does.
run_check gui-default "${launcher[@]}" "$tool" gui "$bundle" "$states/default.vst3state" "$out/default.png"
run_check gui-multipoint-curve "${launcher[@]}" "$tool" gui "$bundle" "$states/multipoint-curve.vst3state" \
    "$out/multipoint-curve.png" 0.25 "$out/multipoint-curve-wet-0.25.png"

if [ "$reference" != - ]; then
    for picture in default multipoint-curve multipoint-curve-wet-0.25; do
        run_check "compare-$picture" "$tool" compare "$out/$picture.png" "ci-results/$reference/gui/$picture.png" \
            "$max_share"
    done
fi

if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    {
        echo "### $label: editor window"
        echo
        echo "$table"
        echo
    } >>"$GITHUB_STEP_SUMMARY"
fi
exit $failed
