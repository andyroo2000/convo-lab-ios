#!/bin/zsh

set -euo pipefail
umask 077

readonly project_root="${0:A:h:h}"
readonly asc_key_id="${ASC_KEY_ID:-K7S44PRTVS}"
readonly asc_issuer_id="${ASC_ISSUER_ID:-ec6ccb2b-2805-4650-bd40-f3bdd1776062}"
readonly development_team="${DEVELOPMENT_TEAM:-USU4D882GM}"
readonly credentials_root="${CONVOLAB_CREDENTIALS_ROOT:-${HOME}/.appstoreconnect}"
readonly asc_key_path="${ASC_KEY_PATH:-${credentials_root}/private_keys/AuthKey_${asc_key_id}.p8}"
readonly distribution_key_path="${DISTRIBUTION_KEY_PATH:-${credentials_root}/ConvoLabDistribution.key.pem}"
readonly distribution_certificate_path="${DISTRIBUTION_CERTIFICATE_PATH:-${credentials_root}/ConvoLabDistribution.cer}"
readonly build_number="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
readonly output_root="${OUTPUT_ROOT:-${project_root}/build/TestFlight/${build_number}}"
readonly archive_path="${output_root}/ConvoLab.xcarchive"
readonly export_path="${output_root}/export"
readonly signing_keychain="${output_root}/convolab-testflight-signing.keychain-db"
readonly keychain_password_file="${output_root}/keychain-password.txt"
readonly distribution_p12="${output_root}/distribution.p12"
readonly distribution_identity="${DISTRIBUTION_IDENTITY:-Apple Distribution: ANDREW BRODIE LANDRY (USU4D882GM)}"
readonly -a original_keychains=(
    "${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}"
)

cleanup_signing_material() {
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    if [[ -e "${signing_keychain}" ]]; then
        security delete-keychain "${signing_keychain}" >/dev/null 2>&1 || true
    fi
    for ephemeral_file in "${keychain_password_file}" "${distribution_p12}"; do
        if [[ -e "${ephemeral_file}" ]]; then
            /bin/unlink "${ephemeral_file}"
        fi
    done
}

for required_file in \
    "${asc_key_path}" \
    "${distribution_key_path}" \
    "${distribution_certificate_path}"; do
    if [[ ! -f "${required_file}" ]]; then
        print -u2 "Missing required signing file: ${required_file}"
        exit 1
    fi
done

if [[ -e "${output_root}" ]]; then
    print -u2 "Output already exists: ${output_root}"
    print -u2 "Choose another BUILD_NUMBER or OUTPUT_ROOT."
    exit 1
fi

mkdir -p "${output_root}"
chmod 700 "${output_root}"
trap cleanup_signing_material EXIT INT TERM

openssl rand -base64 32 > "${keychain_password_file}"
IFS= read -r signing_keychain_password < "${keychain_password_file}"

openssl pkcs12 -export -legacy \
    -inkey "${distribution_key_path}" \
    -in "${distribution_certificate_path}" \
    -out "${distribution_p12}" \
    -name "ConvoLab Apple Distribution" \
    -passout "pass:${signing_keychain_password}"
chmod 600 "${distribution_p12}"

security create-keychain -p "${signing_keychain_password}" "${signing_keychain}"
security set-keychain-settings -lut 21600 "${signing_keychain}"
security unlock-keychain -p "${signing_keychain_password}" "${signing_keychain}"
security import "${distribution_p12}" \
    -k "${signing_keychain}" \
    -P "${signing_keychain_password}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "${signing_keychain_password}" \
    "${signing_keychain}"
security find-identity -v -p codesigning "${signing_keychain}" \
    | grep -F "${distribution_identity}" >/dev/null
security list-keychains -d user -s \
    "${signing_keychain}" \
    "${original_keychains[@]}"

cd "${project_root}"

xcodebuild archive \
    -project ConvoLab.xcodeproj \
    -scheme ConvoLab \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "${archive_path}" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${asc_key_path}" \
    -authenticationKeyID "${asc_key_id}" \
    -authenticationKeyIssuerID "${asc_issuer_id}" \
    DEVELOPMENT_TEAM="${development_team}" \
    CURRENT_PROJECT_VERSION="${build_number}"

readonly archived_info="${archive_path}/Products/Applications/ConvoLab.app/Info.plist"
readonly archived_api_url="$(/usr/libexec/PlistBuddy -c 'Print :APIBaseURL' "${archived_info}")"
if [[ "${archived_api_url}" != "https://convo-lab.com" ]]; then
    print -u2 "Refusing to upload a non-production build: ${archived_api_url}"
    exit 1
fi

xcodebuild -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_path}" \
    -exportOptionsPlist Config/TestFlightExportOptions.plist

xcrun altool --upload-app \
    -f "${export_path}/ConvoLab.ipa" \
    --apiKey "${asc_key_id}" \
    --apiIssuer "${asc_issuer_id}" \
    --p8-file-path "${asc_key_path}" \
    --wait

print "Uploaded ConvoLab build ${build_number} to TestFlight."
