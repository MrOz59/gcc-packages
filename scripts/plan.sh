#!/usr/bin/env bash
# Print, as a JSON array for a GitHub Actions matrix, the pins to work on.
#
# Usage:
#   plan.sh build  [pin] [rebuild]   pins that have no release yet
#   plan.sh verify [pin]             the newest release of each pin
#
# With no pin, every file in pins/ is considered. Each entry has the pin name,
# the release tag and, for build, the release title. Needs gh (authenticated
# through GH_TOKEN) and jq; GITHUB_REPOSITORY names this repository.

set -euo pipefail

mode="${1:?usage: plan.sh build|verify [pin] [rebuild]}"
only="${2:-}"
rebuild="${3:-0}"
repo="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to owner/name}"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

case "${mode}" in
    build | verify) ;;
    *)
        echo "Unknown mode '${mode}'." >&2
        exit 1
        ;;
esac
if [[ ! ${rebuild} =~ ^[0-9]+$ ]]; then
    echo "The rebuild number must be a non-negative integer, got '${rebuild}'." >&2
    exit 1
fi
if (( rebuild > 0 )) && [[ -z ${only} ]]; then
    echo "A rebuild has to name the pin it applies to." >&2
    exit 1
fi

if [[ -n ${only} ]]; then
    if [[ ! ${only} =~ ^[a-z0-9][a-z0-9._-]*$ || ! -f ${here}/pins/${only}.env ]]; then
        echo "There is no pin named '${only}' in pins/." >&2
        exit 1
    fi
    pins=("${here}/pins/${only}.env")
else
    shopt -s nullglob
    pins=("${here}"/pins/*.env)
    shopt -u nullglob
fi

released="$(gh api --paginate "repos/${repo}/releases?per_page=100" --jq '.[].tag_name')"

entries=()
for pin_file in "${pins[@]}"; do
    pin="$(basename -- "${pin_file}" .env)"
    # Each pin is read in a subshell so no value leaks into the next one.
    entry="$(
        # shellcheck source=../pins/gcc14.env
        . "${pin_file}"
        if [[ ${AUR_PACKAGE} != "${pin}" ]]; then
            echo "pins/${pin}.env sets AUR_PACKAGE=${AUR_PACKAGE}; the file must be named after it." >&2
            exit 1
        fi
        # GitHub rewrites '+' in asset names, so the tag, which is part of
        # every consumer's Server URL, avoids it too.
        base="${AUR_PACKAGE}-${PKGVER//+/.}-${PKGREL}"

        if [[ ${mode} == build ]]; then
            tag="${base}"
            title="${AUR_PACKAGE} ${PKGVER}-${PKGREL}"
            if (( rebuild > 0 )); then
                tag="${base}.rebuild${rebuild}"
                title="${title} (rebuild ${rebuild})"
            fi
            if grep -qxF -- "${tag}" <<< "${released}"; then
                echo "${tag} is already released; skipping ${pin}." >&2
                exit 0
            fi
            jq -cn --arg pin "${pin}" --arg tag "${tag}" --arg title "${title}" \
                '{pin: $pin, tag: $tag, title: $title}'
        else
            # The plain tag counts as rebuild 0; the highest rebuild wins.
            tag="$(
                grep -xE -- "${base//./\\.}(\\.rebuild[0-9]+)?" <<< "${released}" \
                    | awk -v base="${base}" '{ n = ($0 == base) ? 0 : substr($0, length(base) + 9) + 0; print n "\t" $0 }' \
                    | sort -n | tail -n 1 | cut -f 2
            )" || true
            if [[ -z ${tag} ]]; then
                echo "${pin} has no release for ${base} yet; skipping it." >&2
                exit 0
            fi
            jq -cn --arg pin "${pin}" --arg tag "${tag}" '{pin: $pin, tag: $tag}'
        fi
    )"
    if [[ -n ${entry} ]]; then
        entries+=("${entry}")
    fi
done

if (( ${#entries[@]} == 0 )); then
    echo "[]"
else
    printf '%s\n' "${entries[@]}" | jq -cs .
fi
