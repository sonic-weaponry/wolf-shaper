#!/usr/bin/env bash
# Tests the macOS installer on this machine. Meant for a CI runner: it installs into /Library and removes it again.
#   1. What the package holds: one component with the official v1.0.2 package identifier, installed into
#      /Library/Audio/Plug-Ins/VST3, no bundle relocation, no scripts, a welcome text and the GPL in the License pane,
#      and exactly our built bundle plus the license, credits and source files.
#   2. Clean install, then uninstall.
#   3. Install over the official v1.0.2 installer (all its formats, as the dmg installs them): our VST3 replaces the
#      official one and its receipt; the official VST2, LV2 and CLAP stay as they were.
#   4. Back to the official installer over ours: report only, for the customer sheet. Then uninstall everything,
#      the official VST2, LV2 and CLAP too, so the machine is as it was.
# On each installed copy of ours: the files are exactly the package's, owned by root:wheel, the receipt is ours, and
# the ids, params, states and instance checks pass on Apple Silicon and on Intel (Rosetta).
#
# A signed package (PKG_SIGNED, ci/README.md "Signing"): the bundle in it is our build plus the license files plus
# the seal (Contents/_CodeSignature/CodeResources), its program carries our build's code and data byte for byte
# (ci/macho_same_code.py: only the signature differs), and on every installed copy the seal holds.
#   PKG_SIGNED=rehearsal     the plugin signed with the throwaway identity; installed with -allowUntrusted (needed
#                            only if the installer itself carries an untrusted signature)
#   PKG_SIGNED=developer-id  signed with our Developer ID certificates: the installed copy must also meet Apple's
#                            Developer ID requirement for $APPLE_TEAM_ID
# PKG_RUN_NAME names the log folder (default: pkg) and prefixes the installed copies' check names.
#
# Usage: ci/check_pkg.sh <vst3_check> <our .pkg> <version> <our built wolf-shaper.vst3> <official .pkg>
# Run it from the repository root, with sudo rights. Logs go to ci-results/pkg/ and ci-results/macos-*-installed-*/.
# Exits 1 if any check failed.
set -u

tool=$1
pkg=$2
version=$3
built=$4
official=$5

id=studio.kx.distrho.plugins.wolf-shaper.vst3bundles
installed=/Library/Audio/Plug-Ins/VST3/wolf-shaper.vst3
binary=$installed/Contents/MacOS/wolf-shaper
official_sha=${OFFICIAL_MAC_SHA256:-unknown}
others=(/Library/Audio/Plug-Ins/VST/wolf-shaper.vst /Library/Audio/Plug-Ins/LV2/wolf-shaper.lv2
    /Library/Audio/Plug-Ins/CLAP/wolf-shaper.clap)
signed=${PKG_SIGNED:-}
case $signed in
    "" | rehearsal) ;;
    developer-id) : "${APPLE_TEAM_ID:?the Team ID is missing (the APPLE_TEAM_ID secret)}" ;;
    *) echo "PKG_SIGNED must be empty, rehearsal or developer-id"; exit 2 ;;
esac
run=${PKG_RUN_NAME:-pkg}
prefix=${PKG_RUN_NAME:+$PKG_RUN_NAME-}
out=ci-results/$run
work=$(mktemp -d)
mkdir -p "$out"
failed=0
table="| Check | Result |
|---|---|"

result() {
    if [ "$1" = PASS ]; then
        echo "PASS $2"
    else
        echo "::error::FAIL $2"
        failed=1
    fi
    table="$table
| $2 | $1 |"
}

# check <name> <command...>: runs the command (its output goes to the log) and records PASS or FAIL.
check() {
    local name=$1
    shift
    if "$@"; then result PASS "$name"; else result FAIL "$name"; fi
}

# --- 1. What the package holds
pkgutil --expand-full "$pkg" "$work/expanded" >/dev/null
comp=$work/expanded/dpf-wolf-shaper-vst3bundles.pkg
payload=$comp/Payload/wolf-shaper.vst3
echo "::group::Distribution and PackageInfo"
cat "$work/expanded/Distribution"
echo
cat "$comp/PackageInfo"
echo "::endgroup::"

# The installer's script and the component's description, read as XML.
structure=$(python3 - "$work/expanded" "$id" "$version" <<'PY'
import os, sys, xml.etree.ElementTree as ET
root, ident, version = sys.argv[1:4]
problems = []
components = sorted(n for n in os.listdir(root) if n.endswith(".pkg"))
if components != ["dpf-wolf-shaper-vst3bundles.pkg"]:
    problems.append("component packages: %s" % components)
dist = ET.parse(os.path.join(root, "Distribution")).getroot()
options = dist.find("options")
if options is None or "arm64" not in (options.get("hostArchitectures") or "").split(","):
    problems.append("hostArchitectures doesn't name arm64 (the Installer would ask for Rosetta)")
for pane in ("welcome", "license"):
    node = dist.find(pane)
    if node is None or not os.path.isfile(os.path.join(root, "Resources", node.get("file", ""))):
        problems.append("no %s pane, or its file is missing" % pane)
info = ET.parse(os.path.join(root, "dpf-wolf-shaper-vst3bundles.pkg", "PackageInfo")).getroot()
for key, want in (("identifier", ident), ("version", version), ("auth", "root")):
    if info.get(key) != want:
        problems.append("PackageInfo %s is %r, not %r" % (key, info.get(key), want))
if (info.get("install-location") or "").rstrip("/") != "/Library/Audio/Plug-Ins/VST3":
    problems.append("install location %r" % info.get("install-location"))
relocate = info.find("relocate")
if relocate is not None and len(relocate):
    problems.append("bundles marked relocatable: %s" % [b.get("id") for b in relocate])
scripts = info.find("scripts")
if scripts is not None and len(scripts):
    problems.append("the package runs scripts")
upgrade = info.find("upgrade-bundle")
print("upgrade-bundle: %s" % ([b.get("id") for b in upgrade] if upgrade is not None else []))
print("bundles: %s" % [(b.get("id"), b.get("path"), b.get("CFBundleVersion")) for b in info.iter("bundle") if b.get("path")])
for p in problems:
    print("PROBLEM " + p)
PY
) || structure="$structure
PROBLEM the structure check crashed"
echo "$structure"
if grep -q '^PROBLEM' <<<"$structure"; then result FAIL "package structure"; else result PASS "package structure"; fi

# The payload: our built bundle unchanged, plus exactly these files (and the seal, when signed), and nothing outside
# the bundle. Signed, the program differs from our build only in its signature.
extra=$(printf '%s\n' "CREDITS and SOURCE.txt" "LICENSE (GPL-3.0).txt" "LICENSES/Chivo font (SIL OFL 1.1).txt" \
    "LICENSES/DPF (ISC).txt" "LICENSES/DSPFilters (MIT).txt" "LICENSES/DejaVu Sans font (Bitstream Vera).txt" \
    "LICENSES/NanoVG (zlib).txt" "LICENSES/pugl (ISC).txt" | sed 's|^|./Contents/Resources/|')
if [ -n "$signed" ]; then
    extra="$extra
./Contents/_CodeSignature/CodeResources"
fi
want=$({ (cd "$built" && find . -type f); echo "$extra"; } | LC_ALL=C sort)
have=$(cd "$payload" && find . -type f | LC_ALL=C sort)
same=PASS
[ "$want" = "$have" ] || { same=FAIL; diff <(echo "$want") <(echo "$have"); }
[ "$(cd "$comp/Payload" && ls -A)" = wolf-shaper.vst3 ] || { same=FAIL; echo "the payload holds more than the bundle"; }
while IFS= read -r f; do
    if [ -n "$signed" ] && [ "$f" = ./Contents/MacOS/wolf-shaper ]; then
        python3 ci/macho_same_code.py "$built/$f" "$payload/$f" || { same=FAIL; echo "the signed program differs from our build beyond its signature"; }
    else
        cmp -s "$built/$f" "$payload/$f" || { same=FAIL; echo "differs from our build: $f"; }
    fi
done < <(cd "$built" && find . -type f)
commit=$(git rev-parse HEAD)
grep -q "tree/$commit" "$payload/Contents/Resources/CREDITS and SOURCE.txt" || { same=FAIL; echo "credits: no link to $commit"; }
grep -q "tree/$commit" "$work/expanded/Resources/welcome.txt" || { same=FAIL; echo "welcome: no link to $commit"; }
echo "--- the bundle in the package"
(cd "$payload" && find . -type f -exec ls -l {} + | tr -s ' ' | cut -d ' ' -f 1,5,9-)
result $same "payload: our build plus the license, credits and source files${signed:+ and the seal, the program's code and data our build's}"

echo "--- the package's signature (${signed:-unsigned dry run: none expected})"
pkgutil --check-signature "$pkg" || true

# --- Helpers for the install scenarios
# A rehearsal package signed by a certificate no Mac trusts would need -allowUntrusted; an unsigned one doesn't mind it.
install_pkg() {
    local code=0
    if [ "$signed" = rehearsal ]; then
        sudo installer -pkg "$1" -target / -verboseR -allowUntrusted >"$out/install-$2.log" 2>&1 || code=$?
    else
        sudo installer -pkg "$1" -target / -verboseR >"$out/install-$2.log" 2>&1 || code=$?
    fi
    grep -v -e '^installer:PHASE' -e '^installer:%' "$out/install-$2.log"
    return $code
}

developer_id_requirement() {
    echo "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\""
}

receipt_is() {
    pkgutil --pkg-info "$id" | grep -qx "version: $1"
}

check_installed() {
    local label=$1 launcher arch wrong
    echo "::group::installed files ($label)"
    find "$installed" -exec stat -f '%Sp %Su:%Sg %N' {} +
    pkgutil --pkg-info "$id"
    echo "::endgroup::"
    check "$label: the installed bundle is exactly the package's" diff -r "$payload" "$installed"
    wrong=$(find "$installed" \( ! -user root -o ! -group wheel -o \( -type d ! -perm 755 \) -o \
        \( -type f ! -path "$binary" ! -perm 644 \) -o \( -path "$binary" ! -perm 755 \) \) -print)
    [ -z "$wrong" ] || echo "owner or mode wrong: $wrong"
    check "$label: owned by root:wheel, folders and the binary 755, the rest 644" test -z "$wrong"
    check "$label: the receipt is ours ($version)" receipt_is "$version"
    if [ -n "$signed" ]; then
        check "$label: the installed copy's seal holds" codesign --verify --deep --strict --verbose=2 "$installed"
    fi
    if [ "$signed" = developer-id ]; then
        check "$label: the installed copy meets Apple's Developer ID requirement for our team" \
            codesign --verify --deep --strict -R="$(developer_id_requirement)" "$installed"
    fi
    for launcher in "" "arch -x86_64"; do
        arch=arm64
        [ -n "$launcher" ] && arch=x86_64
        # shellcheck disable=SC2086
        check "$label: ids, params, states, instance on the installed copy, $arch" \
            bash ci/run_checks.sh "$tool" "$installed" ours "macos-$arch-installed-$prefix$label" $launcher
    done
}

uninstall() {
    local gone=PASS
    sudo rm -rf "$installed"
    sudo pkgutil --forget "$id" >/dev/null
    [ ! -e "$installed" ] || gone=FAIL
    pkgutil --pkg-info "$id" >/dev/null 2>&1 && gone=FAIL
    result $gone "$1: uninstalled (bundle and receipt gone)"
}

hash_others() {
    local d
    for d in "${others[@]}"; do
        if [ -e "$d" ]; then find "$d" -type f -exec shasum -a 256 {} +; fi
    done | LC_ALL=C sort
}

# --- 2. Clean install
if [ -e "$installed" ] || pkgutil --pkg-info "$id" >/dev/null 2>&1 || [ -n "$(hash_others)" ]; then
    result FAIL "clean: this machine already has Wolf Shaper installed, so a clean install can't be tested"
else
    check "clean: the installer succeeds" install_pkg "$pkg" clean
    check_installed clean
    uninstall clean
fi

# --- 3. Over the official v1.0.2 installer
check "over-official: the official v1.0.2 installer succeeds" install_pkg "$official" official
code=0
"$tool" ids "$installed" official ci/frozen/class-ids.txt >"$out/ids-official-installed.log" 2>&1 || code=$?
grep '^RESULT' "$out/ids-official-installed.log"
check "over-official: before ours, the official VST3 is installed (official class IDs)" test $code -eq 0
before=$(hash_others)
echo "official files installed besides the VST3: $(grep -c . <<<"$before")"
check "over-official: the official installer also put its VST2, LV2 and CLAP in place" test -n "$before"
check "over-official: our installer succeeds" install_pkg "$pkg" over-official
check_installed over-official
check "over-official: the official VST2, LV2 and CLAP are untouched" test "$(hash_others)" = "$before"
echo "--- receipts"
pkgutil --pkgs | grep -i wolf-shaper

# --- 4. Back to the official installer (report only)
echo "::group::back to the official v1.0.2 installer (report only)"
code=0
install_pkg "$official" back-to-official || code=$?
echo "installer exit code $code"
find "$installed" -exec stat -f '%Sp %Su:%Sg %z %N' {} +
pkgutil --pkg-info "$id"
"$tool" ids "$installed" official ci/frozen/class-ids.txt 2>&1 | grep '^RESULT'
echo "::endgroup::"
echo "REPORT back to the official: installer exit code $code," \
    "binary $(shasum -a 256 "$binary" | cut -c 1-8)..." \
    "(official ${official_sha:0:8}...), $(find "$installed" -type f | wc -l | tr -d ' ') files in the bundle," \
    "receipt $(pkgutil --pkg-info "$id" | grep '^version')"
uninstall back-to-official

# Leave the machine as it was, so the checks can run again on it (the signing rehearsal does): the official
# installer's other formats and their receipts go too.
for d in "${others[@]}"; do
    sudo rm -rf "$d"
done
for format in vst2bundles lv2bundles clapbundles; do
    sudo pkgutil --forget "studio.kx.distrho.plugins.wolf-shaper.$format" >/dev/null 2>&1 || true
done

rm -rf "$work"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### macOS installer (${signed:-unsigned})"
        echo
        echo "$table"
        echo
    } >>"$GITHUB_STEP_SUMMARY"
fi
exit $failed
