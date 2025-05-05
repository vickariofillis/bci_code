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
    
    # Determine the corresponding run script
    if [ "$startup" = "startup.sh" ]; then
        runfile="run.sh"
    else
        # Extract the numeric (and underscore) suffix, e.g. _1, _13, etc.
        suffix="${startup#startup}"
        suffix="${suffix%.sh}"
        runfile="run${suffix}.sh"
    fi

    # Check if the run script exists and add it to the archive list
    if [ -f "$runfile" ]; then
        echo "  Found associated $runfile"
        chmod +x "$runfile"
        files_to_archive+=("$runfile")
    fi

    # Always include cpus_off.sh if present
    if [ -f "cpus_off.sh" ]; then
        echo "  Adding cpus_off.sh to archive"
        chmod +x "cpus_off.sh"
        files_to_archive+=("cpus_off.sh")
    else
        echo "  Warning: cpus_off.sh not found—skipping"
    fi

    # Create a tar.gz archive with the base name (e.g., startup_1.tar.gz)
    tar -czvf "${base}.tar.gz" "${files_to_archive[@]}"
done
