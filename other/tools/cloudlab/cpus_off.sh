#!/bin/bash
# Off-line all CPUs except CPU 0

# How many CPUs are currently online?
total=$(nproc)

# Loop from CPU 1 to CPU (total − 1)
for cpu in $(seq 1 $(( total - 1 ))); do
  echo 0 | sudo tee /sys/devices/system/cpu/cpu${cpu}/online
done

# Verify only cpu0 remains
echo "Remaining online CPUs:" 
cat /sys/devices/system/cpu/online
