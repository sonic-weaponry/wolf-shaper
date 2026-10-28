#!/usr/bin/env bash
# Runs the four frozen-value checks on one VST3 bundle, one process per check, and reports the results.
#
# Usage: ci/run_checks.sh <vst3_check> <bundle> <ours|official> <label> [<launcher>...]
#   <launcher> is an optional command to run the check tool through, e.g. "arch -x86_64" for the Intel slice on macOS.
#
# Run it from the repository root. Logs and the generated tables go to ci-results/<label>/, and a results table to
# $GITHUB_STEP_SUMMARY when that is set. Exits 1 if any check failed. A check also fails when the plugin prints a DPF
# assertion or warning: a host that follows the VST3 rules never triggers one.

tool=$1
bundle=$2
build=$3
label=$4
shift 4
launcher=("$@")

out="ci-results/$label"
frozen=ci/frozen
mkdir -p "$out"
failed=0
table="| Check | Result | Detail |
|---|---|---|"

run_check() {
    name=$1
    shift
    log="$out/$name.log"
    err="$out/$name.stderr.log"
    "${launcher[@]}" "$tool" "$name" "$bundle" "$@" >"$log" 2>"$err"
    code=$?

    result_line=$(grep '^RESULT ' "$log" | tail -n 1)
    if [ $code -eq 0 ] && [ -n "$result_line" ]; then
        result=PASS
    else
        result=FAIL
    fi
    detail=${result_line#RESULT $name PASS }
    detail=${detail#RESULT $name FAIL }
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

run_check ids "$build" "$frozen/class-ids.txt"
run_check params "$frozen/parameters.json" "$out/parameters.json"
run_check states "$frozen"/states/*.vst3state
run_check instance "$frozen/plugin-info.json" "$out/plugin-info.json"

if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    {
        echo "### $label"
        echo
        echo "$table"
        echo
    } >>"$GITHUB_STEP_SUMMARY"
fi
exit $failed
