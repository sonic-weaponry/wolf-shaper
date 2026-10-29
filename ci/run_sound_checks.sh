#!/usr/bin/env bash
# Renders the public test states through one VST3 bundle for the sound null test: every state at 44.1 and 48 kHz, in
# blocks of 512 and 64, through ci/vst3_check render (10 s of silence, then the test signal). Then the block-64 renders
# must equal the block-512 renders bit for bit: Wolf Shaper works sample by sample and keeps every filter's memory
# across blocks, so the block size must not change the sound.
#
# Usage: ci/run_sound_checks.sh <vst3_check> <bundle> <label> <signal folder> <renders folder> [<launcher>...]
#   <signal folder> holds test-signal-44100.wav and test-signal-48000.wav (ci/make_test_signal.py).
#   <launcher> is an optional command to run the check tool through, e.g. "arch -x86_64" for the Intel slice.
#
# Run it from the repository root. Renders go to <renders folder>/<label>/<state>-<rate>-<block>.wav, logs to
# ci-results/<label>/sound/, a results table to $GITHUB_STEP_SUMMARY when that is set. Exits 1 if a render failed or
# the block sizes don't agree. As in ci/run_checks.sh, a render also fails when the plugin prints a DPF assertion or
# warning.

tool=$1
bundle=$2
label=$3
signals=$4
renders=$5
shift 5
launcher=("$@")

# The first Python that runs (on Windows, "python3" can be a stub that only offers to install Python).
python=
for candidate in python3 python; do
    if "$candidate" -c "import sys" >/dev/null 2>&1; then
        python=$candidate
        break
    fi
done
logs="ci-results/$label/sound"
out="$renders/$label"
mkdir -p "$logs" "$out"
failed=0
rendered=0
problems=""

for state in ci/frozen/states/*.vst3state; do
    name=$(basename "$state" .vst3state)
    for rate in 44100 48000; do
        for block in 512 64; do
            wav="$out/$name-$rate-$block.wav"
            log="$logs/$name-$rate-$block.log"
            err="$logs/$name-$rate-$block.stderr.log"
            "${launcher[@]}" "$tool" render "$bundle" "$state" "$signals/test-signal-$rate.wav" "$block" "$wav" >"$log" 2>"$err"
            code=$?
            result_line=$(grep '^RESULT ' "$log" | tail -n 1)
            dpf_lines=$(grep -e 'assertion failure' -e 'DPF warning' "$err" | head -n 3)
            if [ $code -ne 0 ] || [ -z "$result_line" ] || [ -n "$dpf_lines" ]; then
                failed=1
                problems="$problems
$name $rate Hz block $block: ${result_line:-no RESULT line (exit code $code)} $dpf_lines"
                echo "::group::$label render $name $rate Hz block $block: FAIL"
                cat "$log" "$err"
                echo "::endgroup::"
            else
                rendered=$((rendered + 1))
                echo "$label $name $rate Hz block $block: $(grep '^OUTPUT ' "$log")"
            fi
        done
    done
done

# Block 64 against block 512, file by file.
pairs=()
for wav in "$out"/*-512.wav; do
    [ -e "$wav" ] || continue
    other=${wav%-512.wav}-64.wav
    [ -e "$other" ] && pairs+=("$wav" "$other")
done
if [ ${#pairs[@]} -gt 0 ]; then
    "$python" ci/null_test.py --identical --label "$label: block 64 against block 512" "${pairs[@]}" | tee "$logs/blocks.log"
    [ "${PIPESTATUS[0]}" -eq 0 ] || failed=1
else
    failed=1
fi

summary="$rendered renders; $(grep '^NULL TEST' "$logs/blocks.log" 2>/dev/null | tail -n 1)"
echo "$label sound: $([ $failed -eq 0 ] && echo PASS || echo FAIL) $summary$problems"
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    {
        echo "### $label: sound"
        echo
        echo "$([ $failed -eq 0 ] && echo PASS || echo FAIL): $summary"
        [ -n "$problems" ] && echo "\`\`\`$problems
\`\`\`"
        echo
    } >>"$GITHUB_STEP_SUMMARY"
fi
exit $failed
