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

    # Create the tar.gz
    tar -czvf "$tarball" "${files_to_archive[@]}"
done
