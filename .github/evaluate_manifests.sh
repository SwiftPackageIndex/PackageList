#!/usr/bin/env bash

# Evaluates every manifest set that was fetched for it, each in its own restricted container.
# The fetching step - validate.swift for a submission, `validator check-dependencies` for the
# nightly audit - writes one directory per package into the handover directory. `manifests/` for
# the Package*.swift files, `url` for the package they came from.
#
# The container is where third party manifest code runs, so it has no network, no token, an
# unprivileged uid, nothing writable and a wall clock. All that comes back out of it is an
# exit status per package.
#
# SPI_EVALUATION_MODE picks what a manifest that does not load means:
#
#   fail   (default) the run fails. A submitted package that does not build is the submitter's
#          problem and they need to hear about it.
#   report the package is marked `failed` and the run continues. A candidate dependency that does
#          not build is simply not added, and one bad package on the index must not stop the
#          nightly audit.

set -uo pipefail

manifest_root="${1:?usage: evaluate_manifests.sh <directory the manifests were fetched into>}"
timeout_seconds="${SPI_MANIFEST_TIMEOUT:-120}"
mode="${SPI_EVALUATION_MODE:-fail}"
: "${SWIFT_IMAGE:?SWIFT_IMAGE must be set to the image CI evaluates manifests with}"

case "$mode" in
    fail|report) ;;
    *) echo "SPI_EVALUATION_MODE must be 'fail' or 'report', not '$mode'"; exit 1 ;;
esac

# A manifest can simply refuse to finish, and SwiftPM runs it in a process group of its own,
# so signalling the process group we started does not reach it. The termination of the container's
# PID 1 takes the whole PID namespace with it.
evaluate() {
    docker run --rm \
        --label spi-manifest-evaluation \
        --network none \
        --user 65534:65534 \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --pids-limit 256 \
        --memory 2g \
        --cpus 2 \
        --ulimit nofile=1024 \
        --ulimit fsize=104857600 \
        --tmpfs /tmp:rw,exec,mode=1777,size=1g \
        --env HOME=/tmp \
        --env SPI_PROCESSING=1 \
        --volume "$1:/pkg:ro" \
        --workdir /pkg \
        "$SWIFT_IMAGE" \
        timeout --signal=KILL "$timeout_seconds" \
        swift package --scratch-path /tmp/scratch dump-package > /dev/null
}

sanitized() {
    tr -d '\r\n' | tr -cd '[:alnum:] .,:/_@-' | cut -c1-200
}

report_failure() {
    [ -n "${GITHUB_OUTPUT:-}" ] || return 0
    echo "validateError=$1" >> "$GITHUB_OUTPUT"
}

# A handover directory that is missing entirely means the two steps disagree about where it
# is, which would otherwise look exactly like a run with nothing to evaluate.
[ -d "$manifest_root" ] || { echo "no handover directory at $manifest_root"; exit 1; }

shopt -s nullglob
evaluated=()
failed=()

for directory in "$manifest_root"/*/; do
    [ -d "$directory/manifests" ] || continue
    package="$(sanitized < "$directory/url" 2>/dev/null)"
    package="${package:-$directory}"
    echo "evaluating manifests for $package"
    evaluated+=("$package")
    if ! evaluate "$directory/manifests"; then
        failed+=("$package")
        # The marker goes beside `manifests`, never inside it, so nothing the container could
        # reach can forge it.
        [ "$mode" = report ] && touch "$directory/failed"
    fi
done

if [ "$mode" = report ]; then
    # Signing off so the next step can tell "nothing failed" apart from "this never ran".
    touch "$manifest_root/evaluated"
    [ "${#failed[@]}" != 0 ] && printf 'could not evaluate: %s\n' "${failed[@]}"
    echo "evaluated ${#evaluated[@]} package(s), ${#failed[@]} did not load"
    exit 0
fi

if [ "${#failed[@]}" != 0 ]; then
    printf 'manifest evaluation failed: %s\n' "${failed[@]}"
    report_failure "manifest evaluation failed: ${failed[0]}"
    exit 1
fi

echo "evaluated ${#evaluated[@]} package(s), every manifest loaded"
