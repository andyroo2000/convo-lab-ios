#!/bin/zsh
# Requires zsh for path modifiers and process substitution on macOS CI.

set -euo pipefail

readonly project_root="${0:A:h:h}"
readonly provider_repository="${LEARNING_OS_REPOSITORY:-${project_root:h}/learning-os}"
readonly provider_commit="6f557e9ff7819bfee6c12d6e845ac28056475bdb"
readonly provider_root="tests/Fixtures/Compatibility"
readonly destination_root="${project_root}/ConvoLabTests/Fixtures/Compatibility"
readonly manifest_sha256="fd156e09c95b0c731be8a5599af4fbd4d619174667de448dc1c42d6ffa2f0c1c"
readonly -a fixture_files=(
    manifest-v1.json
    manifest-v1.sha256
    study-card-summary-v1.json
    study-card-summary-v1.sha256
    google-calendar-connection-v1.json
    google-calendar-connection-v1.sha256
    study-activity-analytics-v1.json
    study-activity-analytics-v1.sha256
    daily-audio-practice-v1.json
    daily-audio-practice-v1.sha256
    personal-weekly-recap-v1.json
    personal-weekly-recap-v1.sha256
    known-kanji-v2.json
    known-kanji-v2.sha256
    wanikani-transfer-bridge-update-v1.json
    wanikani-transfer-bridge-update-v1.sha256
)

usage() {
    print -u2 "Usage: ${0:t} [--verify|--sync]"
}

readonly mode="${1:---verify}"
if [[ "${mode}" != "--verify" && "${mode}" != "--sync" ]] || (( $# > 1 )); then
    usage
    exit 64
fi

if ! git -C "${provider_repository}" cat-file -e "${provider_commit}^{commit}" 2>/dev/null; then
    print -u2 "Pinned Learning OS commit is unavailable: ${provider_commit}"
    print -u2 "Set LEARNING_OS_REPOSITORY to a checkout containing that commit."
    exit 1
fi

if [[ "${mode}" == "--sync" ]]; then
    mkdir -p "${destination_root}"
fi

for file in "${fixture_files[@]}"; do
    provider_object="${provider_commit}:${provider_root}/${file}"
    destination="${destination_root}/${file}"
    if [[ "${mode}" == "--sync" ]]; then
        git -C "${provider_repository}" show "${provider_object}" > "${destination}"
    elif [[ ! -f "${destination}" ]] || ! cmp -s \
        <(git -C "${provider_repository}" show "${provider_object}") \
        "${destination}"; then
        print -u2 "Vendored fixture differs from ${provider_object}: ${file}"
        exit 1
    fi
done

readonly actual_manifest_sha256="$(shasum -a 256 "${destination_root}/manifest-v1.json" | awk '{print $1}')"
if [[ "${actual_manifest_sha256}" != "${manifest_sha256}" ]]; then
    print -u2 "Unexpected compatibility manifest digest: ${actual_manifest_sha256}"
    exit 1
fi

(
    cd "${destination_root}"
    for checksum in *.sha256; do
        shasum -a 256 -c "${checksum}"
    done
)

print "Compatibility fixtures match and verify against Learning OS ${provider_commit}."
