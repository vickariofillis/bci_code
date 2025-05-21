#!/bin/bash
set -euo pipefail

# Loop over all test profiles (skip the generic startup.sh)
for startup in startup_*.sh; do
    # If no files match, glob stays literal—skip that
    [ -e "$startup" ] || continue

    # Derive base name and tarball name
    base="${startup%.sh}"              # e.g. "startup_20" or "startup_20_3gram"
    tarball="${base}.tar.gz"

    echo "Processing ${tarball} ..."

    # Always include the startup script itself
    chmod +x "$startup"
    files_to_archive=("$startup")

    # Strip "startup_" prefix, split into ID and optional suffix
    tmp="${base#startup_}"             # yields "20", "20_3gram", etc.
    id="${tmp%%_*}"                    # yields "20"
    rest=""
    if [[ "$tmp" == *_* ]]; then
        rest="${tmp#${id}_}"           # yields "3gram", "5gram", etc.
    fi

    if [[ -z "$rest" ]]; then
        # Generic ID case → run_<ID>.sh
        runfile="run_${id}.sh"
        if [[ -f "$runfile" ]]; then
            chmod +x "$runfile"
            files_to_archive+=("$runfile")
        fi
    else
        # Suffix case → run_<ID>_<rest>.sh and any run_<ID>_<rest>_*.sh
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

    # Always include cpus_off.sh if it exists
    if [[ -f "cpus_off.sh" ]]; then
        chmod +x "cpus_off.sh"
        files_to_archive+=("cpus_off.sh")
    fi

    # Create the tar.gz
    tar -czvf "$tarball" "${files_to_archive[@]}"
done
