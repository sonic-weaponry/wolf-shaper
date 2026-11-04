#!/usr/bin/env bash
# The temporary keychain that holds the signing identities on a CI runner (ci/README.md, "Signing").
#
#   ci/keychain.sh setup <keychain> <kind> <.p12>:<password variable> [<.p12>:<password variable> ...]
#     Creates the keychain with a random password (masked, never printed), imports each .p12 (its password read from
#     the environment variable named after the colon) and Apple's Developer ID G2 intermediate certificate (checked
#     against Apple's root on this machine), lets codesign and productbuild use the keys without a prompt, and puts the
#     keychain first in the search list. Then finds the two identities by the start of their names:
#       kind "developer-id": "Developer ID Application: " and "Developer ID Installer: ", both ending in
#         "($APPLE_TEAM_ID)", and naming $EXPECTED_SIGNER if that is set;
#       kind "rehearsal": the throwaway "Wolf Shaper CI rehearsal Application" and "... Installer" identities
#         (ci/make_test_identity.sh).
#     Prints them and writes keychain=, app_identity= (the SHA-1), app_name= and installer_name= to $GITHUB_OUTPUT.
#   ci/keychain.sh delete <keychain>
#     Deletes the keychain and its search-list entry. Fine to run when it doesn't exist.
#
# Run it on macOS. The .p12 files can be deleted as soon as setup returns.
set -euo pipefail

action=$1
kc=$2

if [ "$action" = delete ]; then
    if security delete-keychain "$kc" 2>/dev/null; then
        echo "deleted $kc"
    else
        echo "no keychain $kc to delete"
    fi
    exit 0
fi
[ "$action" = setup ] || { echo "usage: ci/keychain.sh setup|delete <keychain> ..."; exit 2; }

kind=$3
shift 3
case $kind in
    developer-id)
        app_prefix="Developer ID Application: "
        installer_prefix="Developer ID Installer: "
        : "${APPLE_TEAM_ID:?the Team ID is missing (the APPLE_TEAM_ID secret)}"
        ;;
    rehearsal)
        app_prefix="Wolf Shaper CI rehearsal Application"
        installer_prefix="Wolf Shaper CI rehearsal Installer"
        ;;
    *) echo "unknown kind $kind"; exit 2 ;;
esac

password=$(openssl rand -hex 24)
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$password"
fi
rm -f "$kc"
security create-keychain -p "$password" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$password" "$kc"

for spec in "$@"; do
    p12=${spec%%:*}
    variable=${spec#*:}
    if [ ! -s "$p12" ]; then
        echo "::error::$p12 is empty or missing"
        exit 1
    fi
    if [ -z "${!variable:-}" ]; then
        echo "::error::the password for $(basename "$p12") is empty ($variable)"
        exit 1
    fi
    security import "$p12" -k "$kc" -f pkcs12 -P "${!variable}" -A -t cert >/dev/null
    echo "imported $(basename "$p12")"
done

# Apple's Developer ID G2 intermediate: Developer ID certificates made with the G2 profile chain to Apple's root through
# it, and signatures carry the whole chain. It's public; macOS itself checks it chains to Apple Root CA.
intermediate=$(mktemp -d)/DeveloperIDG2CA.cer
if curl -fsSL --retry 3 --retry-delay 5 -o "$intermediate" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer &&
    security verify-cert -c "$intermediate" >/dev/null &&
    openssl x509 -inform DER -in "$intermediate" -noout -subject | grep -q 'Developer ID Certification Authority'; then
    openssl x509 -inform DER -in "$intermediate" -noout -subject -issuer -enddate -fingerprint -sha256
    security import "$intermediate" -k "$kc" -t cert >/dev/null || true
    echo "imported Apple's Developer ID G2 intermediate (verified against this Mac's Apple root)"
elif security find-certificate -c "Developer ID Certification Authority" /Library/Keychains/System.keychain >/dev/null 2>&1; then
    echo "::warning::couldn't download Apple's Developer ID G2 intermediate; this runner's System keychain has one"
elif [ "$kind" = developer-id ]; then
    echo "::error::couldn't get Apple's Developer ID G2 intermediate certificate"
    exit 1
else
    echo "::warning::couldn't get Apple's Developer ID G2 intermediate (the rehearsal doesn't need it)"
fi

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$kc" >/dev/null
# This keychain first, then the ones already in the user's search list.
others=()
while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#\"}
    line=${line%\"}
    [ -n "$line" ] && [ "$line" != "$kc" ] && others+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$kc" ${others[@]+"${others[@]}"}

identities=$(security find-identity -p basic "$kc")
echo "--- identities in the signing keychain"
echo "$identities"

# find_identity <name prefix>: "<SHA-1> <name>" of the first identity whose certificate name starts with the prefix.
find_identity() {
    local line re='^ *[0-9]+\) ([0-9A-F]{40}) "([^"]*)"'
    while IFS= read -r line; do
        if [[ $line =~ $re ]]; then
            case ${BASH_REMATCH[2]} in
                "$1"*) echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; return 0 ;;
            esac
        fi
    done <<<"$identities"
    return 0
}

app=$(find_identity "$app_prefix")
installer=$(find_identity "$installer_prefix")
if [ -z "$app" ] || [ -z "$installer" ]; then
    echo "::error::the keychain lacks an identity starting with '$app_prefix' or '$installer_prefix'"
    exit 1
fi
app_sha=${app%% *}
app_name=${app#* }
installer_name=${installer#* }

if [ "$kind" = developer-id ]; then
    for name in "$app_name" "$installer_name"; do
        case $name in
            *" ($APPLE_TEAM_ID)") ;;
            *) echo "::error::'$name' isn't for our team (APPLE_TEAM_ID)"; exit 1 ;;
        esac
    done
    if [ -n "${EXPECTED_SIGNER:-}" ] && { [ "$app_name" != "${app_prefix}$EXPECTED_SIGNER ($APPLE_TEAM_ID)" ] ||
        [ "$installer_name" != "${installer_prefix}$EXPECTED_SIGNER ($APPLE_TEAM_ID)" ]; }; then
        echo "::error::the certificates aren't in the name of $EXPECTED_SIGNER: '$app_name', '$installer_name'"
        exit 1
    fi
fi

for name in "$app_name" "$installer_name"; do
    security find-certificate -c "$name" -p "$kc" | openssl x509 -noout -subject -enddate
done
echo "bundle signer:    $app_name ($app_sha)"
echo "installer signer: $installer_name"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "keychain=$kc"
        echo "app_identity=$app_sha"
        echo "app_name=$app_name"
        echo "installer_name=$installer_name"
    } >>"$GITHUB_OUTPUT"
fi
