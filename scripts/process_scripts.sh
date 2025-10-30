#!/bin/bash
set -euo pipefail

# Loop over all test profiles (including the generic startup.sh)
for startup in startup*.sh; do
    # Skip if no matching file
    [ -e "$startup" ] || continue

    # Derive base name and tarball name
    base="${startup%.sh}"              # e.g. "startup" or "startup_20" or "startup_20_3gram"
    tarball="${base}.tar.gz"

    echo "Processing ${tarball} ..."

    # Always include the startup script itself
    chmod +x "$startup"
    files_to_archive=("$startup")

    # Ensure shared helpers travel with every archive so sourced functions resolve.
    if [[ -f helpers.sh ]]; then
        files_to_archive+=("helpers.sh")
    fi

    # Include the super_run orchestrator so batch automation is available offline.
    if [[ -f super_run.sh ]]; then
        chmod +x "super_run.sh"
        files_to_archive+=("super_run.sh")
    fi

    # Strip "startup_" prefix, split into ID and optional suffix
    tmp="${base#startup_}"             # yields "","20","20_3gram", etc.
    id="${tmp%%_*}"                    # yields "","20"
    rest=""
    if [[ "$tmp" == *_* ]]; then
        rest="${tmp#${id}_}"           # yields "3gram", etc.
    fi

    if [[ -z "$rest" ]]; then
        # Generic case (no suffix): add run_<ID>.sh if it exists
        runfile="run_${id}.sh"
        if [[ -f "$runfile" ]]; then
            chmod +x "$runfile"
            files_to_archive+=("$runfile")
        fi
    else
        # Suffix case: add run_<ID>_<rest>.sh and any run_<ID>_<rest>_*.sh
        runfile="run_${id}_${rest}.sh"
        if [[ -f "$runfile" ]]; then
            chmod +x "$runfile"
            files_to_archive+=("$runfile")
        fi
        for spec in run_${id}_${rest}_*.sh; do
            if [[ -f "$spec" ]]; then
                chmod +x "$spec"
                files_to_archive+=("$spec")
            fi
        done
    fi

    ID="${id}"

    # Include activity breadcrumbs and the super log for provenance
    EXTRA_PROVENANCE=()
    if [[ -n "${ID}" ]]; then
        [ -f "/local/data/results/super/${ID}/super_run.log" ] && \
            EXTRA_PROVENANCE+=("/local/data/results/super/${ID}/super_run.log")
        [ -d "/local/activity/${ID}" ] && \
            EXTRA_PROVENANCE+=("/local/activity/${ID}/")
    fi

    # Create the tar.gz
    tar --exclude='*.pid' --exclude='*.tmp' --exclude='.inprogress' --transform 's|^/||' -czvf "$tarball" \
        "${EXTRA_PROVENANCE[@]}" \
        "${files_to_archive[@]}"
done
