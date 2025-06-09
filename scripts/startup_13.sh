#!/bin/bash
set -euo pipefail

################################################################################

### Log keeping

# Get ownership of /local and grant read and execute permissions to everyone
ORIG_USER=${SUDO_USER:-$(id -un)}
ORIG_GROUP=$(id -gn "$ORIG_USER")
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod -R a+rx /local
# Create a logs directory if it doesn't exist.
mkdir -p /local/logs
# Redirect all output (stdout and stderr) to a log file.
# This will both write to the file and still display output in the console.
exec > >(tee -a /local/logs/startup.log) 2>&1

################################################################################

### Clone bci_code repo

# Move to proper directory
cd /local
# Clone directory
git clone https://github.com/vickariofillis/bci_code.git
# Make Maya tool
cd bci_code/tools/maya
make CONF=Release

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

### Increase storage

# 1) Detect hardware
hw_model="unknown"
if [ -r /sys/devices/virtual/dmi/id/product_name ]; then
  hw_model=$(cat /sys/devices/virtual/dmi/id/product_name)
fi
echo "Hardware model: $hw_model"

# 2) Storage setup by model
case "$hw_model" in

  # Any C220 family (c240g5, c220g2, UCSC-C220-M4S, etc.)
  *c240g5*|*C240G5*|*c220g2*|*C220G2*|*C220*|*UCSC-C220*)
    echo "→ Detected C220/C240 family: partitioning /dev/sdb → /local/data"

    desired_gb=300
    if [ ! -b /dev/sdb1 ]; then
      echo "Partition /dev/sdb1 missing, creating new on /dev/sdb…"
      total_bytes=$(sudo blockdev --getsize64 /dev/sdb)
      total_gb=$(( total_bytes / 1024 / 1024 / 1024 ))
      echo "Disk /dev/sdb is ${total_gb}GB"

      if [ "$total_gb" -ge "$desired_gb" ]; then
        partition_end="${desired_gb}GB"
      else
        partition_end="${total_gb}GB"
      fi
      echo "Creating partition 0–${partition_end}"

      sudo parted /dev/sdb --script mklabel gpt
      sudo parted /dev/sdb --script mkpart primary ext4 0GB $partition_end
      sleep 5
    fi

    echo "Formatting /dev/sdb1 as ext4…"
    sudo mkfs.ext4 -F /dev/sdb1

    echo "Mounting /dev/sdb1 at /local/data…"
    sudo mkdir -p /local/data
    sudo mount /dev/sdb1 /local/data
    ;;

  # XL170 family
  *XL170*|*xl170*|*ProLiant\ XL170r*|*XL170r*)
    echo "→ Detected XL170: expanding /dev/sda3 to fill SSD…"

    if ! command -v growpart &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y cloud-guest-utils
    fi

    echo "Running growpart /dev/sda 3"
    sudo growpart /dev/sda 3

    echo "Resizing ext4 on /dev/sda3"
    sudo resize2fs /dev/sda3

    echo "Ensuring /local/data exists"
    sudo mkdir -p /local/data
    ;;

  # Any other hardware
  *)
    echo "→ Unrecognized hardware ($hw_model)."
    echo "   Please add a case for this node or attach a blockstore in your RSpec."
    exit 1
    ;;
esac

# 3) Final check
echo "=== /local/data usage ==="
df -h /local/data
echo "========================="

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
# sudo curl -fsSL https://www.mathworks.com/mpm/glnxa64/mpm -o "${MPM_PATH}"
sudo wget -O "${MPM_PATH}" https://www.mathworks.com/mpm/glnxa64/mpm
sudo chmod 755 "${MPM_PATH}"

# 7. Download MATLAB R2024b
mkdir -p "${DOWNLOAD_DIR}"
"${MPM_PATH}" download \
  --release R2024b \
  --products MATLAB \
  --destination "${DOWNLOAD_DIR}"

# 8a. Install MATLAB
mkdir -p "${INSTALL_DIR}"
"${MPM_PATH}" install \
  --source "${DOWNLOAD_DIR}" \
  --destination "${INSTALL_DIR}" \
  --products MATLAB

# 8b. Redirect MATLAB prefs into a writable folder under /local
MATLAB_PREFROOT="/local/tools/matlab_prefs"
MATLAB_PREFDIR="$MATLAB_PREFROOT/R2024b"

sudo mkdir -p   "$MATLAB_PREFDIR"
sudo chown -R   "$ORIG_USER:$ORIG_GROUP" "$MATLAB_PREFROOT"
sudo chmod -R u+rwX "$MATLAB_PREFROOT"

echo "→ MATLAB_PREFDIR set to $MATLAB_PREFDIR"

# 9. License checkout verification
export MLM_LICENSE_FILE="${MLM_PORT}@${LICENSE_SERVER}"
export LM_LICENSE_FILE="$MLM_LICENSE_FILE"

echo "→ Testing MATLAB license checkout…"
sudo -u "$ORIG_USER" env \
    MLM_LICENSE_FILE="$MLM_LICENSE_FILE" \
    LM_LICENSE_FILE="$LM_LICENSE_FILE" \
    MATLAB_PREFDIR="$MATLAB_PREFDIR" \
  "${MATLAB_BIN}" -nodisplay -nosplash -nodesktop \
    -batch "\
      fprintf('PREFDIR=%s\n',prefdir); \
      s=license('test','MATLAB'); \
      fprintf('Licensed? %d\n',s); \
      exit(~s);"

if [ $? -eq 0 ]; then
  echo "✅ MATLAB R2024b installed and licensed successfully."
else
  echo "❌ MATLAB license checkout failed." >&2
  exit 1
fi

################################################################################

### Setting up ID-13 (Movement Intent)

# Clone repo in case it was not fetched earlier
cd /local
if [ ! -d bci_code ]; then
  git clone https://github.com/vickariofillis/bci_code.git
fi

# Create directories
mkdir -p tools
cd tools

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

# Get ownership of /local and grant read and execute permissions to everyone
echo "→ Will set /local → $ORIG_USER:$ORIG_GROUP …"
sudo chown -R "$ORIG_USER":"$ORIG_GROUP" /local
chmod    -R a+rx                  /local

###  Final verification of /local ownership & permissions
# Determine who *should* own /local (the user who invoked sudo, or yourself if not using sudo)
EXPECTED_USER=${SUDO_USER:-$(id -un)}
EXPECTED_GROUP=$(id -gn "$EXPECTED_USER")
echo "Verifying that everything under /local is owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and has a+rx..."

# 1) Any file not owned by EXPECTED_USER:EXPECTED_GROUP?
bad_owner=$(find /local \
    ! -user "$EXPECTED_USER" -o ! -group "$EXPECTED_GROUP" \
    -print -quit 2>/dev/null || true)

# 2) Any entry missing read for all? (i.e. not -r--r--r--)
bad_read=$(find /local \
    ! -perm -444 \
    -print -quit 2>/dev/null || true)

# 3) Any entry missing exec for all? (i.e. not --x--x--x--)
bad_exec=$(find /local \
    ! -perm -111 \
    -print -quit 2>/dev/null || true)

if [[ -z "$bad_owner" && -z "$bad_read" && -z "$bad_exec" ]]; then
    echo "✅ All files under /local are owned by ${EXPECTED_USER}:${EXPECTED_GROUP} and have a+rx"
else
    [[ -n "$bad_owner" ]] && echo "❌ Ownership mismatch example: $bad_owner"
    [[ -n "$bad_read"  ]] && echo "❌ Missing read bit example:  $bad_read"
    [[ -n "$bad_exec"  ]] && echo "❌ Missing exec bit example:  $bad_exec"
    exit 1
fi
