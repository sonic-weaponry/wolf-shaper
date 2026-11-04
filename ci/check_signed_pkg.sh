#!/usr/bin/env bash
# Checks the signatures of a signed macOS installer and of the plugin inside it (ci/README.md, "Signing").
#
#   ci/check_signed_pkg.sh rehearsal <.pkg>
#     After packaging/macos/make_pkg.sh with the throwaway identities (ci/make_test_identity.sh): the bundle's seal
#     holds in both slices, with the hardened runtime, no entitlements and the bundle's own identifier, signed by the
#     throwaway identity; the package carries the throwaway signature. Gatekeeper rejects both, as it should for a
#     certificate no Mac trusts; that's printed, not checked.
#   ci/check_signed_pkg.sh developer-id <.pkg> [<folder with Apple's notarization log>]
#     The same with Apple's chain: the bundle signed by "Developer ID Application: $EXPECTED_SIGNER ($APPLE_TEAM_ID)",
#     with a secure timestamp and meeting Apple's Developer ID requirement for our team, the package by "Developer ID
#     Installer: ..." with a trusted timestamp. With the log folder (packaging/macos/notarize.sh's): Apple accepted
#     exactly this package with no issues, and its ticket covers the plugin's two slices; the ticket is stapled and
#     validates; Gatekeeper accepts the package as "Notarized Developer ID".
#
# Run it from the repository root on macOS. Logs go to ci-results/signing-<kind>/. Exits 1 if any check failed.
set -u

kind=$1
pkg=$2
logs=${3:-}
case $kind in
    rehearsal) signer_prefix="Wolf Shaper CI rehearsal" ;;
    developer-id)
        : "${APPLE_TEAM_ID:?the Team ID is missing (the APPLE_TEAM_ID secret)}"
        signer_prefix="Developer ID"
        ;;
    *) echo "usage: ci/check_signed_pkg.sh rehearsal|developer-id <.pkg> [log folder]"; exit 2 ;;
esac

out=ci-results/signing-$kind
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

has_line() { grep -qxF -- "$1" <<<"$2"; }
has_text() { grep -qF -- "$1" <<<"$2"; }

pkgutil --expand-full "$pkg" "$work/expanded" >/dev/null
bundle=$work/expanded/dpf-wolf-shaper-vst3bundles.pkg/Payload/wolf-shaper.vst3

# --- The plugin bundle
check "bundle: the seal holds (codesign --verify --deep --strict)" codesign --verify --deep --strict --verbose=2 "$bundle"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
for arch in arm64 x86_64; do
    info=$(codesign -dvvv --architecture "$arch" "$bundle" 2>&1)
    echo "$info" >"$out/codesign-$arch.txt"
    echo "::group::codesign -dvvv --architecture $arch"
    echo "$info"
    echo "::endgroup::"
    check "bundle, $arch: the signature verifies" codesign --verify --strict --architecture "$arch" "$bundle"
    check "bundle, $arch: identifier $identifier (the Info.plist's)" has_line "Identifier=$identifier" "$info"
    check "bundle, $arch: hardened runtime" grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' <<<"$info"
    check "bundle, $arch: Info.plist and resources sealed" grep -Eq '^Sealed Resources version=2 rules=[0-9]+ files=[1-9]' <<<"$info"
    check "bundle, $arch: signed by a '$signer_prefix' identity" grep -q "^Authority=$signer_prefix" <<<"$info"
    if [ "$kind" = developer-id ]; then
        check "bundle, $arch: chain Developer ID Application: ${EXPECTED_SIGNER:-} (team), Developer ID CA, Apple Root CA" \
            test "$(grep '^Authority=' <<<"$info")" = "Authority=Developer ID Application: ${EXPECTED_SIGNER:-?} ($APPLE_TEAM_ID)
Authority=Developer ID Certification Authority
Authority=Apple Root CA"
        check "bundle, $arch: our team" has_line "TeamIdentifier=$APPLE_TEAM_ID" "$info"
        check "bundle, $arch: secure timestamp" grep -q '^Timestamp=' <<<"$info"
    else
        echo "REPORT bundle, $arch: $(grep -E '^(Timestamp|Signed Time)=' <<<"$info" | head -n 1)"
    fi
done
entitlements=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null)
check "bundle: no entitlements" test -z "$entitlements"
if [ "$kind" = developer-id ]; then
    requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\""
    check "bundle: meets Apple's Developer ID requirement for our team" \
        codesign --verify --deep --strict -R="$requirement" "$bundle"
fi

# --- The installer package
signature=$(pkgutil --check-signature "$pkg" 2>&1)
echo "$signature" >"$out/pkgutil-check-signature.txt"
echo "::group::pkgutil --check-signature"
echo "$signature"
echo "::endgroup::"
if [ "$kind" = developer-id ]; then
    check "package: signed by a developer certificate issued by Apple for distribution" \
        has_text "Status: signed by a developer certificate issued by Apple for distribution" "$signature"
    chain=$(sed -n 's/^ *[0-9]\. //p' <<<"$signature" | grep -v '^SHA' | grep -v '^ ' | head -n 3)
    check "package: chain Developer ID Installer: ${EXPECTED_SIGNER:-} (team), Developer ID CA, Apple Root CA" \
        test "$chain" = "Developer ID Installer: ${EXPECTED_SIGNER:-?} ($APPLE_TEAM_ID)
Developer ID Certification Authority
Apple Root CA"
    check "package: trusted timestamp" has_text "Signed with a trusted timestamp" "$signature"
else
    check "package: signed by the throwaway installer identity" has_text "Wolf Shaper CI rehearsal Installer" "$signature"
fi

# --- Notarization, staple, Gatekeeper
gatekeeper=$(spctl --assess --type install -vvv "$pkg" 2>&1)
echo "Gatekeeper: $gatekeeper" | tr '\n' ' '
echo
if [ "$kind" = developer-id ] && [ -n "$logs" ]; then
    notary=$(python3 - "$logs/notary-log.json" "$logs/submitted.sha256" <<'PY'
import json, sys
log = json.load(open(sys.argv[1]))
submitted = open(sys.argv[2]).read().split()[0]
problems = []
if log.get("status") != "Accepted":
    problems.append("status %r" % log.get("status"))
if log.get("issues"):
    problems.append("issues: %s" % json.dumps(log["issues"]))
if log.get("sha256") != submitted:
    problems.append("Apple checked a different file (sha256 %s, submitted %s)" % (log.get("sha256"), submitted))
archs = sorted({t.get("arch") for t in log.get("ticketContents") or []
                if "wolf-shaper.vst3/Contents/MacOS/wolf-shaper" in t.get("path", "")})
print("ticket covers the plugin's slices: %s" % archs)
if archs != ["arm64", "x86_64"]:
    problems.append("the ticket doesn't cover both slices of the plugin")
for p in problems:
    print("PROBLEM " + p)
PY
) || notary="PROBLEM the log couldn't be read"
    echo "$notary"
    check "notarization: Apple accepted this exact package with no issues, and its ticket covers both slices" \
        test -z "$(grep '^PROBLEM' <<<"$notary")"
    check "staple: the ticket is stapled to the package and validates" xcrun stapler validate -v "$pkg"
    check "Gatekeeper: accepts the package as Notarized Developer ID" \
        grep -q 'accepted' <<<"$gatekeeper"
    check "Gatekeeper: source is Notarized Developer ID" has_text "source=Notarized Developer ID" "$gatekeeper"
    check "package: notarization trusted (pkgutil)" has_text "Notarization: trusted by the Apple notary service" "$signature"
fi

rm -rf "$work"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Signatures ($kind)"
        echo
        echo "$table"
        echo
    } >>"$GITHUB_STEP_SUMMARY"
fi
exit $failed
