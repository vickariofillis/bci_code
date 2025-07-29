#!/bin/bash
set -euo pipefail

# Raspberry Pi setup for ID-1 (Seizure Detection)

REPO_DIR="/home/vic/bci_code"
DATA_DIR="/home/vic/data/id_1"
LOG_DIR="/home/vic/logs"

mkdir -p "$LOG_DIR" "$DATA_DIR"
exec > >(tee -a "$LOG_DIR/startup_1.log") 2>&1

echo "==== ID-1 startup (Raspberry Pi) ===="

# Clone repo if missing
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Cloning bci_code into $REPO_DIR"
  git clone https://github.com/vickariofillis/bci_code.git "$REPO_DIR"
fi

# Fetch data files if absent
cd "$DATA_DIR"
if [ ! -f data.h ]; then
  echo "Downloading data.h"
  curl -L "https://drive.usercontent.google.com/download?id=1HFm67GHZZbtzRSB4ZXcjuUNn5Gh9uI93&confirm=xxx" -o data.h
fi
if [ ! -f data2.h ]; then
  echo "Downloading data2.h"
  curl -L "https://drive.usercontent.google.com/download?id=1Yi9pr8-RFxi_9xgks_7h_HWjAZ5tmTnu&confirm=xxx" -o data2.h
fi

# Copy data into repository
cp -u data.h data2.h "$REPO_DIR/id_1/"


# Build Maya if missing
cd "$REPO_DIR/tools/maya"
if [ ! -x Dist/Release/Maya ]; then
  echo "Building Maya profiler"
  make CONF=Release
fi

# Build the workload (ID-1)
cd "$REPO_DIR/id_1"
gcc -std=c99 -fopenmp main.c -o main -lm

echo "Startup complete"
