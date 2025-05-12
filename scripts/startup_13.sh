#!/bin/bash
set -euo pipefail

################################################################################

### Log keeping

# Get ownership of /local
chown -R $USER /local
# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### Function for setting a title to the terminal tab

bashrc="$HOME/.bashrc"

# Don’t add it twice
if ! grep -q 'function set-title' "$bashrc"; then
  cat <<'EOF' >> "$bashrc"

# Set Title to a terminal tab
function set-title() {
    if [[ -z "$orig" ]]; then
        orig=$PS1
    fi
    title="\[\e]2;$*\a\]"
    PS1=${orig}${title}
}
EOF

  echo "✅ set-title() added to $bashrc"
else
  echo "ℹ️  set-title() already present in $bashrc"
fi

# Reload ~/.bashrc so you can use it immediately
# (you can also just open a new shell)
source "$bashrc"

################################################################################

### Partition, Format, and Mount /dev/sdb at /local/data with 300GB or Maximum Available

# Desired partition size in GB
desired_gb=300

# Check if partition /dev/sdb1 exists; if not, create it.
if [ ! -b /dev/sdb1 ]; then
    echo "Partition /dev/sdb1 not found. Preparing to create a new partition on /dev/sdb."

    # Get total size of /dev/sdb in bytes
    total_bytes=$(sudo blockdev --getsize64 /dev/sdb)
    # Convert total size to GB (integer approximation)
    total_gb=$(echo "$total_bytes/1024/1024/1024" | bc)
    echo "Total size of /dev/sdb: ${total_gb}GB"

    # Determine the partition end point: desired size or total size, whichever is smaller.
    if [ "$total_gb" -ge "$desired_gb" ]; then
        partition_end="${desired_gb}GB"
    else
        partition_end="${total_gb}GB"
    fi
    echo "Will create partition ending at: $partition_end"

    # Create a new GPT partition table and a primary partition.
    sudo parted /dev/sdb --script mklabel gpt
    sudo parted /dev/sdb --script mkpart primary ext4 0GB $partition_end

    # Allow the kernel time to recognize the new partition.
    sleep 5
fi

# Format the partition as ext4 (this will erase any existing data on /dev/sdb1).
echo "Formatting /dev/sdb1 as ext4..."
sudo mkfs.ext4 -F /dev/sdb1

# Create the mount point and mount the partition.
echo "Mounting /dev/sdb1 at /local/data..."
sudo mkdir -p /local/data
sudo mount /dev/sdb1 /local/data

# Verify the mount.
df -h /local/data

################################################################################

### General updates

# Update the package lists.
sudo apt-get update
# Install essential packages: git and build-essential.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential ppp pptp-linux cpuset

################################################################################

### Create general directories
cd /local; mkdir -p tools; mkdir -p data;
cd data/; mkdir -p results;

################################################################################

### Installing pmu-tools

# Change directories
cd /local/tools/;
# Clone the pmu-tools repository.
git clone https://github.com/andikleen/pmu-tools.git
cd pmu-tools/
# Install python3-pip and then install the required Python packages.
sudo apt-get install -y python3-pip
pip install -r requirements.txt
# Adjust kernel parameters to enable performance measurements.
sudo sysctl -w 'kernel.perf_event_paranoid=-1'
sudo sysctl -w 'kernel.nmi_watchdog=0'
# Install perf tools.
sudo apt-get install -y linux-tools-common linux-tools-generic linux-tools-$(uname -r)
# Download events (for toplev)
sudo /local/tools/pmu-tools/event_download.py

################################################################################

### Install ECE VPN

# === User configuration ===


DOWNLOAD_DIR="/local/tools/matlab_download"
INSTALL_DIR="/local/tools/matlab"
MPM_PATH="/usr/local/bin/mpm"
MATLAB_BIN="${INSTALL_DIR}/bin/matlab"

# 1. Install & configure PPTP VPN client
sudo tee /etc/ppp/options.pptp >/dev/null << 'EOF'
noauth
nodefaultroute
EOF

sudo tee /etc/ppp/chap-secrets >/dev/null << EOF
${USERNAME} PPTP ${PASSWORD} *
PPTP ${USERNAME} ${PASSWORD} *
EOF
sudo chmod 600 /etc/ppp/chap-secrets

sudo tee /etc/ppp/peers/ecevpn >/dev/null << EOF
pty "pptp ${VPN_SERVER} --nolaunchpppd"
name ${USERNAME}
remotename PPTP
require-mschap-v2
require-mppe-128
file /etc/ppp/options.pptp
ipparam ecevpn
EOF

sudo tee /etc/ppp/ip-up.d/static_route >/dev/null << 'EOF'
#!/bin/bash
if [ "\${PPP_IPPARAM}" = "ecevpn" ]; then
  for net in 128.100.7.0/24 128.100.9.0/24 128.100.10.0/24 \
             128.100.11.0/24 128.100.12.0/24 128.100.15.0/24 \
             128.100.23.0/24 128.100.24.0/24 128.100.51.0/24 \
             128.100.138.0/24 128.100.221.0/24 128.100.244.0/24; do
    route add -net \$net gw \${PPP_REMOTE} dev \${PPP_IFACE}
  done
fi
EOF
sudo chmod 755 /etc/ppp/ip-up.d/static_route

# 2. Bring up the VPN
sudo poff ecevpn 2>/dev/null || true
sudo pon ecevpn

# 3. Wait for ppp0 to exist
echo "Waiting for ppp0 interface…"
for i in {1..8}; do
  if ip link show ppp0 &>/dev/null; then
    echo "  ppp0 is present"
    break
  fi
  sleep 3
done
if ! ip link show ppp0 &>/dev/null; then
  echo "ERROR: ppp0 did not appear" >&2
  exit 1
fi

# 4. Wait for ppp0 to receive an IP address
echo "Waiting for ppp0 IP assignment…"
for i in {1..8}; do
  if ip -4 addr show dev ppp0 | grep -q 'inet '; then
    echo "  ppp0 IP: $(ip -4 addr show dev ppp0 | grep inet)"
    break
  fi
  sleep 3
done
if ! ip -4 addr show dev ppp0 | grep -q 'inet '; then
  echo "ERROR: ppp0 never got an IP" >&2
  exit 1
fi

# 5. Add host route for license server via ppp0
LICENSE_IP=$(getent hosts "$LICENSE_SERVER" | awk '{print $1}')
sudo ip route replace "${LICENSE_IP}/32" dev ppp0
echo "Route to ${LICENSE_IP}: $(ip route get ${LICENSE_IP} | head -n1)"

################################################################################

### Install and license Matlab

# 6. Install MATLAB prerequisites & mpm
sudo apt-get install -y curl unzip libxmu6 libxt6 libx11-6 libglib2.0-0
sudo curl -fsSL https://www.mathworks.com/mpm/glnxa64/mpm -o "${MPM_PATH}"
sudo chmod 755 "${MPM_PATH}"

# 7. Download MATLAB R2024b
mkdir -p "${DOWNLOAD_DIR}"
"${MPM_PATH}" download \
  --release R2024b \
  --products MATLAB \
  --destination "${DOWNLOAD_DIR}"

# 8. Install MATLAB
mkdir -p "${INSTALL_DIR}"
"${MPM_PATH}" install \
  --source "${DOWNLOAD_DIR}" \
  --destination "${INSTALL_DIR}" \
  --products MATLAB

# 9. License checkout verification
export MLM_LICENSE_FILE="${MLM_PORT}@${LICENSE_SERVER}"
if "${MATLAB_BIN}" -batch "disp(['MATLAB ' version]); exit(license('test','MATLAB'))"; then
  echo "✅ MATLAB R2024b installed and licensed successfully."
else
  echo "❌ MATLAB license checkout failed." >&2
  exit 1
fi

################################################################################

### Setting up ID-13 (Movement Intent)

# Create directories
cd /local; mkdir -p tools; cd tools

# Download Fieldtrip
curl -L "https://drive.usercontent.google.com/download?id={1KVb_tsA1KzC7AhaZUKvR0wuR9Ob9bTJe}&confirm=xxx" -o fieldtrip-20240916.zip
# Unzip Fieldtrip
unzip fieldtrip-20240916.zip -d fieldtrip/

# Create directories
cd /local/data;

# Download data files (patient 4)
wget https://osf.io/download/mgn6y/ -O S4_raw_segmented.mat
# Download data files (patient 5)
wget https://osf.io/download/qmsc4/ -O S5_raw_segmented.mat
# Download data files (patient 5)
wget https://osf.io/download/dtqky/ -O S6_raw_segmented.mat

################################################################################