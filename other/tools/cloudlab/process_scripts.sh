#!/bin/bash

# Loop over all .sh files in the current directory
for file in *.sh; do
    # Skip the processing script itself
    if [ "$file" = "process_scripts.sh" ]; then
        continue
    fi
    echo "Processing $file ..."
    # Make the script executable
    chmod +x "$file"
    # Remove the .sh extension to create a base name
    base="${file%.sh}"
    # Create a tar.gz archive with the same base name
    tar -czvf "${base}.tar.gz" "$file"
done