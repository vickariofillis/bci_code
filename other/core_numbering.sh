#!/bin/bash

# 1) Build a numerically sorted list of logical CPU IDs
mapfile -t cpus < <(
  ls -d /sys/devices/system/cpu/cpu[0-9]* |   # list cpu directories
  sed 's!.*/cpu!!' |                          # strip path, keep the number
  sort -n                                    # numeric sort
)

# 2) Iterate in sorted order
for cpu in "${cpus[@]}"; do
  cpu_dir="/sys/devices/system/cpu/cpu${cpu}"
  socket=$(<"$cpu_dir/topology/physical_package_id")
  core=$(<"$cpu_dir/topology/core_id")
  sibs=$(<"$cpu_dir/topology/thread_siblings_list")
  # determine our thread index within the sibling list
  IFS=, read -ra arr <<< "$sibs"
  thread_idx=0
  for i in "${!arr[@]}"; do
    if [ "${arr[$i]}" = "$cpu" ]; then
      thread_idx=$i
      break
    fi
  done
  # print with no extra space before comma
  printf "CPU %-2s → socket %-1s, core %-2s, thread %-1s { %s }\n" \
    "$cpu" "$socket" "$core" "$thread_idx" "$sibs"
done
