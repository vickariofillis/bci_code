#!/bin/bash
set -euo pipefail

# Build per-startup tarballs that include:
#  - the startup script itself
#  - matching run scripts for that ID (and variants)
#  - shared helpers (helpers.sh)
#  - the orchestrator (super_run.sh)
#  - the results packer (get_results.sh)
# Usage: run from the directory that contains startup*.sh and the other scripts.

shopt -s nullglob

for startup in startup*.sh; do
    # Skip if no matching file
    [ -e "$startup" ] || continue

    # Derive base name and tarball name
    base="${startup%.sh}"              # e.g., "startup", "startup_13", "startup_20_3gram"
    tarball="${base}.tar.gz"

    echo "Processing ${tarball} ..."

    # Collect files to archive
    files_to_archive=()

    # 1) startup itself
    chmod +x "$startup"
    files_to_archive+=("$startup")

    # 2) shared helpers
    if [[ -f helpers.sh ]]; then
        chmod +x "helpers.sh"
        files_to_archive+=("helpers.sh")
    fi

    # 3) orchestrator
    if [[ -f super_run.sh ]]; then
        chmod +x "super_run.sh"
        files_to_archive+=("super_run.sh")
    fi

    # 4) results packer
    if [[ -f get_results.sh ]]; then
        chmod +x "get_results.sh"
        files_to_archive+=("get_results.sh")
    fi

    # 5) matching run scripts for this startup
    #    - startup_13           -> include run_13.sh (if present)
    #    - startup_20_3gram     -> include run_20_3gram.sh and run_20_3gram_*.sh (if present)
    #    - startup (no suffix)  -> no specific run script is added here
    tmp="${base#startup_}"             # yields "", "13", "20_3gram", etc.
    id="${tmp%%_*}"                    # "13", "20", or "" if none
    rest=""
    if [[ "$tmp" == *_* ]]; then
        rest="${tmp#${id}_}"           # "3gram", etc.
    fi

    if [[ -n "$id" && -z "$rest" ]]; then
        # e.g., startup_13 -> run_13.sh
        runfile="run_${id}.sh"
        if [[ -f "$runfile" ]]; then
            chmod +x "$runfile"
            files_to_archive+=("$runfile")
        fi
    elif [[ -n "$id" && -n "$rest" ]]; then
        # e.g., startup_20_3gram -> run_20_3gram.sh and run_20_3gram_*.sh
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

    # 6) Create the tar.gz
    tar -czvf "$tarball" "${files_to_archive[@]}"
done
