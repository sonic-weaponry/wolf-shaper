#!/usr/bin/env bash
# Renders private states (saved by users of the plugin, not public) the way ci/run_sound_checks.sh renders the public
# test states, and hands back nothing readable: every render, log and result goes into one archive encrypted to an
# OpenPGP public key, and the console only gets counts and PASS/FAIL. Used by the macos-private job in build.yml.
#
# Usage: ci/run_private_sound.sh <vst3_check> <our bundle> <official bundle> <signal folder> <encrypted output>
#   PRIVATE_STATES      base64 of a tar.gz of *.vst3state files
#   RENDER_PUBLIC_KEY   the ASCII-armored OpenPGP public key the archive is encrypted to
#
# What it renders: our build on arm64 and x86_64 (Rosetta) at 44.1 and 48 kHz, blocks of 512 and 64, and the official
# v1.0.2 on arm64 at both rates, block 512. Then, all inside the archive: block 64 against block 512, our build against
# the official v1.0.2, and the locale check (de_DE.UTF-8) on both builds. The plaintext stays in a private temporary
# folder outside the workspace, so no upload step can pick it up, and is deleted at the end.

tool=$1
ours=$2
official=$3
signals=$4
encrypted=$5

if [ -z "${PRIVATE_STATES:-}" ] || [ -z "${RENDER_PUBLIC_KEY:-}" ]; then
    echo "PRIVATE SOUND: FAIL PRIVATE_STATES or RENDER_PUBLIC_KEY is empty (this job needs the private-tests environment)"
    exit 1
fi

python=
for candidate in python3 python; do
    if "$candidate" -c "import sys" >/dev/null 2>&1; then
        python=$candidate
        break
    fi
done

umask 077
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/private.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/in" "$work/out" "$work/gnupg"
log="$work/out/log.txt"

if ! printf '%s' "$PRIVATE_STATES" | base64 --decode 2>/dev/null | tar -xzf - -C "$work/in" 2>/dev/null; then
    echo "PRIVATE SOUND: FAIL could not unpack PRIVATE_STATES"
    exit 1
fi
states=("$work/in"/*.vst3state)
if [ ! -e "${states[0]}" ]; then
    echo "PRIVATE SOUND: FAIL PRIVATE_STATES holds no .vst3state files"
    exit 1
fi

renders=0
render_failures=0
render() { # <label> <bundle> <state> <rate> <block> [<launcher>...]
    local label=$1 bundle=$2 state=$3 rate=$4 block=$5
    shift 5
    local name code output
    name=$(basename "$state" .vst3state)
    mkdir -p "$work/out/$label"
    local wav="$work/out/$label/$name-$rate-$block.wav"
    output=$("$@" "$tool" render "$bundle" "$state" "$signals/test-signal-$rate.wav" "$block" "$wav" 2>&1)
    code=$?
    printf '=== %s %s %s Hz block %s\n%s\n' "$label" "$name" "$rate" "$block" "$output" >>"$log"
    if [ "$code" -eq 0 ] && [ -e "$wav" ] && ! printf '%s\n' "$output" | grep -q -e 'assertion failure' -e 'DPF warning'; then
        renders=$((renders + 1))
    else
        render_failures=$((render_failures + 1))
    fi
}

for state in "${states[@]}"; do
    for rate in 44100 48000; do
        for block in 512 64; do
            render macos-arm64-ours "$ours" "$state" "$rate" "$block"
            render macos-x86_64-ours "$ours" "$state" "$rate" "$block" arch -x86_64
        done
        render macos-arm64-official "$official" "$state" "$rate" 512
    done
done

# The comparisons, into the log. Each prints a "NULL TEST PASS|FAIL" line.
null_test() { # <label> <args>...
    local label=$1
    shift
    "$python" ci/null_test.py --label "$label" "$@" >>"$log" 2>&1
}
blocks_ok=0
for label in macos-arm64-ours macos-x86_64-ours; do
    pairs=()
    for wav in "$work/out/$label"/*-512.wav; do
        [ -e "$wav" ] && pairs+=("$wav" "${wav%-512.wav}-64.wav")
    done
    [ ${#pairs[@]} -gt 0 ] && null_test "$label: block 64 against block 512" --identical "${pairs[@]}" && blocks_ok=$((blocks_ok + 1))
done
for label in macos-arm64-ours macos-x86_64-ours; do
    pairs=()
    for wav in "$work/out/macos-arm64-official"/*-512.wav; do
        [ -e "$wav" ] && pairs+=("$wav" "$work/out/$label/$(basename "$wav")")
    done
    [ ${#pairs[@]} -gt 0 ] && null_test "$label against the official v1.0.2 on arm64" "${pairs[@]}"
done
for bundle in "$ours" "$official"; do
    for launcher in "" "arch -x86_64"; do
        {
            echo "=== locale: $bundle ${launcher:-arm64}"
            $launcher "$tool" locale "$bundle" de_DE.UTF-8 "${states[@]}" 2>&1
        } >>"$log"
    done
done

# Seal it: an archive of everything, encrypted to the public key, with a keyring of its own.
printf '%s\n' "$RENDER_PUBLIC_KEY" >"$work/key.asc"
if ! tar -czf "$work/bundle.tar.gz" -C "$work/out" . ||
    ! gpg --homedir "$work/gnupg" --batch --quiet --yes --trust-model always --recipient-file "$work/key.asc" \
        --output "$encrypted" --encrypt "$work/bundle.tar.gz" 2>/dev/null; then
    rm -f "$encrypted"
    echo "PRIVATE SOUND: FAIL could not encrypt the results"
    exit 1
fi

echo "PRIVATE SOUND: ${#states[@]} states, $renders renders done, $render_failures failed; block 64 = block 512 for" \
    "$blocks_ok of 2 builds; results encrypted ($(wc -c <"$encrypted" | tr -d ' ') bytes)"
[ "$render_failures" -eq 0 ] && [ "$blocks_ok" -eq 2 ]
