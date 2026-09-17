#!/bin/zsh

# Attaches the JTAG cable to vivado_container over USB/IP (usbipd-mac on the host,
# usbip client inside the container) and applies the udev-rule-equivalent fixups
# this container needs but can't get, since it runs no udev daemon.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

# Vendor IDs Vivado's own cable drivers support, taken from its
# 52-xilinx-*.rules udev files:
#   0x03fd  Xilinx Platform Cable USB/USB II
#   0x0403  FTDI-based cables
#   0x1443  Digilent cables
supported_vendor_ids=(0x03fd 0x0403 0x1443)

usbipd_bin="$script_dir/../mac-tools/usbipd-mac/.build/release/usbipd"
container_name="vivado_container"

# Prints an error message, waits for the user to read it (the window may have
# been opened by double-clicking an alias, with nothing else on screen to
# explain what happened), then exits with status 1.
f_fail() {
    f_echo "$1"
    f_echo "Press Enter to close this window."
    read -r
    exit 1
}

if [[ ! -x "$usbipd_bin" ]]; then
    f_fail "usbipd is missing. Run scripts/setup.sh first — it builds the USB/IP server this needs."
fi

# --- Startup confirmation with timeout ---

f_echo "Press Enter within 5 seconds to connect the JTAG cable."
f_echo "Doing nothing shuts down the usbipd daemon and exits."

if ! read -t 5 -r; then
    # Timeout: no input within 5 seconds
    if pgrep -qf "$usbipd_bin daemon"; then
        f_echo "Shutting down usbipd daemon..."
        sudo pkill -f "$usbipd_bin daemon"
        f_echo "usbipd daemon stopped."
    else
        f_echo "No usbipd daemon running."
    fi
    f_echo "This window will close in 5 seconds."
    sleep 5
    exit 0
fi

# --- Step 1: find the cable ---

f_echo "Looking for a supported JTAG cable..."
list_output=$("$usbipd_bin" list 2>&1)

busid=""
vidpid=""
vid=""
for line in "${(f)list_output}"; do
    candidate=$(grep -oE '0x[0-9a-fA-F]{4}:0x[0-9a-fA-F]{4}' <<< "$line")
    [[ -z "$candidate" ]] && continue
    # lowercased before matching: usbipd currently prints %04x, and a cable that
    # silently "isn't found" because of hex case would be miserable to debug
    candidate=${candidate:l}
    vid=${candidate%%:*}
    # looked up by VID, not hardcoded, since the same cable can show up at a
    # different busid every time it's plugged in
    if (( ${supported_vendor_ids[(Ie)$vid]} )); then
        busid=${${(z)line}[1]}
        vidpid=$candidate
        break
    fi
done

if [[ -z "$busid" ]]; then
    f_echo "No supported JTAG cable found. Currently attached USB devices:"
    echo "$list_output"
    f_fail "Plug in the JTAG cable and run this script again."
fi

f_echo "Found cable $vidpid at busid $busid"

# --- Step 2: make sure the usbipd daemon is running and listening ---

if pgrep -qf "$usbipd_bin daemon"; then
    f_echo "usbipd daemon already running"
else
    f_echo "Starting usbipd daemon (needs sudo for USB access)..."
    sudo "$usbipd_bin" daemon &> /tmp/usbipd-daemon.log &
    disown
fi

f_echo "Waiting for usbipd daemon to listen on port 3240..."
daemon_ready=0
for i in {1..10}; do
    if nc -z localhost 3240 &> /dev/null; then
        daemon_ready=1
        break
    fi
    sleep 1
done

if (( ! daemon_ready )); then
    f_fail "usbipd daemon never started listening on port 3240. Check /tmp/usbipd-daemon.log."
fi

# --- Step 3: bind the device ---

f_echo "Binding $busid..."
bind_output=$(sudo "$usbipd_bin" bind "$busid" 2>&1)
bind_status=$?
echo "$bind_output"

if (( bind_status != 0 )); then
    f_fail "Failed to bind $busid (see message above)."
fi

# --- Step 4: make sure the container is running ---

if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
    f_fail "$container_name is not running. Start it with start_container.sh first."
fi

# --- Step 5: attach the device inside the container ---

f_echo "Attaching $busid inside $container_name..."
if ! docker exec "$container_name" usbip attach -r host.docker.internal -b "$busid"; then
    f_fail "usbip attach failed inside the container."
fi

# --- Step 6: fixups a udev daemon would normally handle ---

vid_hex=${vid#0x}
pid_hex=${vidpid#*:0x}

f_echo "Locating the device node inside the container..."
device_info=$(docker exec -i -u root "$container_name" bash -s -- "$vid_hex" "$pid_hex" <<'INNER'
vid="$1"
pid="$2"
line=$(lsusb | grep -i "ID ${vid}:${pid}")
[[ -z "$line" ]] && exit 1
busnum=$(echo "$line" | awk '{print $2}')
devnum=$(echo "$line" | awk '{print $4}' | tr -d ':')
sysfs=""
for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    if [[ "$(cat "$d/idVendor")" == "$vid" && "$(cat "$d/idProduct")" == "$pid" ]]; then
        sysfs=$(basename "$d")
        break
    fi
done
echo "/dev/bus/usb/${busnum}/${devnum} ${sysfs}"
INNER
)

if [[ -z "$device_info" ]]; then
    f_fail "Could not find $vidpid in the container's lsusb output after attach."
fi

device_node=${device_info%% *}
sysfs_id=${device_info#* }

if [[ -z "$device_node" || -z "$sysfs_id" ]]; then
    f_fail "Could not resolve the device node or sysfs entry for $vidpid."
fi

# hw_server runs as uid 1000 ("user"), not root. On a normal Linux box
# 52-xilinx-pcusb.rules would grant MODE="666" here, but this container runs no
# udev daemon, so nothing applies it to a freshly attached node.
f_echo "Setting permissions on $device_node..."
if ! docker exec -u root "$container_name" chmod 666 "$device_node"; then
    f_fail "Failed to chmod $device_node."
fi

if [[ "$vid" == "0x0403" ]]; then
    f_echo "Unbinding kernel ftdi_sio driver from interfaces 0 and 1 (as 52-xilinx-ftdi-usb.rules does)..."
    docker exec -u root "$container_name" bash -c "
        echo -n '${sysfs_id}:1.0' > /sys/bus/usb/drivers/ftdi_sio/unbind 2> /dev/null
        echo -n '${sysfs_id}:1.1' > /sys/bus/usb/drivers/ftdi_sio/unbind 2> /dev/null
        true
    "
fi

# --- Step 7: verify and report ---

f_echo "Verifying..."
docker exec "$container_name" bash -c "lsusb | grep -i '${vid_hex}:${pid_hex}'"
f_echo "Device node: $device_node"
docker exec "$container_name" bash -c "ls -l '$device_node'"

if [[ "$vidpid" == "0x03fd:0x0013" ]]; then
    # Not hardcoded: the firmware lives under the installed Vivado version's
    # own data directory, and the version isn't known here.
    firmware_path=$(docker exec "$container_name" bash -c 'ls /home/user/Xilinx/*/data/xicom/xusb_xp2.hex 2>/dev/null | head -n1')
    if [[ -z "$firmware_path" ]]; then
        f_fail "This is an unconfigured Xilinx Platform Cable (0x03fd:0x0013) that needs Cypress FX2 firmware, but xusb_xp2.hex was not found under /home/user/Xilinx/*/data/xicom/ inside the container. Is Vivado installed?"
    fi
    f_echo "This is an unconfigured Xilinx Platform Cable (0x03fd:0x0013)."
    f_echo "It needs Cypress FX2 firmware before it can do JTAG. Inside the container, run:"
    f_echo "  fxload -t fx2lp -I $firmware_path -D $device_node"
    f_echo "  (if that reports the wrong chip type, try -t fx2 instead)"
    f_echo "Uploading it makes the cable re-enumerate as 0x03fd:0x0008, which breaks this USB/IP attachment."
    f_echo "Run this script again afterwards to re-bind and re-attach the reconfigured cable."
    f_echo "Run the fxload command above before pressing Enter. Pressing Enter closes this window."
    read -r
    exit 0
else
    f_echo "JTAG cable connected and ready."
    f_echo "This window will close in 5 seconds."
    sleep 5
    exit 0
fi
