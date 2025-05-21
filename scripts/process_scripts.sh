#!/bin/bash

# Loop over all startup scripts in the current directory
for startup in startup*.sh; do
    # Skip if there is no matching file (in case glob doesn't match)
    [ -e "$startup" ] || continue

    echo "Processing $startup ..."

    # Make the startup script executable
    chmod +x "$startup"
    
    # Remove the .sh extension from the startup file to create a base name
    base="${startup%.sh}"
    
    # Initialize an array with the startup script
    files_to_archive=("$startup")
    
    # Determine the corresponding run scripts
    if [ "$startup" = "startup.sh" ]; then
        # legacy single-run case
        runfile="run.sh"
        if [ -f "$runfile" ]; then
            echo "  Found associated $runfile"
            chmod +x "$runfile"
            files_to_archive+=("$runfile")
        fi
    else
        # Extract the numeric (and underscore) suffix, e.g. _1, _13, _20, etc.
        suffix="${startup#startup}"
        suffix="${suffix%.sh}"
        # Glob for any runs matching that suffix, e.g. run_20_*.sh
        for runfile in run${suffix}_*.sh; do
            if [ -f "$runfile" ]; then
                echo "  Found associated $runfile"
                chmod +x "$runfile"
                files_to_archive+=("$runfile")
            fi
        done
    fi

    # Always include cpus_off.sh if present
    if [ -f "cpus_off.sh" ]; then
        echo "  Adding cpus_off.sh to archive"
        chmod +x "cpus_off.sh"
        files_to_archive+=("cpus_off.sh")
    else
        echo "  Warning: cpus_off.sh not found—skipping"
    fi

    # Create a tar.gz archive with the base name (e.g., startup_20.tar.gz)
    tar -czvf "${base}.tar.gz" "${files_to_archive[@]}"
done
