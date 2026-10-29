#!/usr/bin/env bash
# Persist outside actions-runner/_work, which checkout may clean.
set -euo pipefail
mode=${1:?Usage: local-artifacts.sh save|restore software|vivado|bitstream|testbench}
kind=${2:?Missing artifact kind}
[[ $kind == software || $kind == vivado || $kind == bitstream || $kind == testbench ]] || exit 2
root=${LOCAL_ARTIFACT_ROOT:-/home/github-runner/ci-artifacts}
repo=${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $repo != *..* ]] || exit 2
if [[ $mode == save ]]; then
    run_id=${GITHUB_RUN_ID:?}
    attempt=${GITHUB_RUN_ATTEMPT:?}
elif [[ $mode == restore ]]; then
    run_id=${SOURCE_RUN_ID:?}
    attempt=${SOURCE_RUN_ATTEMPT:?}
else
    exit 2
fi
[[ $run_id =~ ^[1-9][0-9]*$ && $attempt =~ ^[1-9][0-9]*$ ]] || exit 2
store="$root/$repo/$run_id/$attempt/$kind"
if [[ $mode == save ]]; then
    if [[ ! -d artifacts/$kind ]]; then
        echo "No $kind output to preserve."
        exit 0
    fi
    mkdir -p "$(dirname "$store")"
    # Each run attempt has its own immutable destination.
    [[ ! -e $store ]] || { echo "ERROR: Storage already exists: $store" >&2; exit 1; }
    staging=$(mktemp -d "${store}.tmp.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    cp -a "artifacts/$kind/." "$staging/"
    mv "$staging" "$store"
    trap - EXIT
else
    [[ -d $store ]] || { echo "ERROR: Local artifact missing on this runner: $store" >&2; exit 1; }
    [[ ! -e artifacts/$kind ]] || { echo 'ERROR: Restore destination already exists.' >&2; exit 1; }
    mkdir -p artifacts
    cp -a "$store" "artifacts/$kind"
fi
echo "Local artifact $mode: $store"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '\nLocal artifact (%s): `%s`\n' "$mode" "$store" >> "$GITHUB_STEP_SUMMARY"
fi
