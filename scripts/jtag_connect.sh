#!/bin/zsh

# Attaches the JTAG cable to vivado_container over USB/IP (usbipd-mac on the host,
# usbip client inside the container) and applies the udev-rule-equivalent fixups
# this container needs but can't get, since it runs no udev daemon.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

# Vendor IDs Vivado's own cable drivers support, taken from its
# 52-xilinx-*.rules udev files:
#   03fd  Xilinx Platform Cable USB/USB II
#   0403  FTDI-based cables
#   1443  Digilent cables
supported_vendor_ids=(03fd 0403 1443)

usbipd_bin="$script_dir/../mac-tools/usbipd-mac/.build/release/usbipd"
# python with the libusb1 module, set up by setup_usbipd.sh
usb_python="$script_dir/../mac-tools/usb-venv/bin/python3"
# built into the image by the Dockerfile
usbip_bin_in_container="usbip"
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

if [[ ! -x "$usbipd_bin" || ! -x "$usb_python" ]]; then
    f_fail "usbipd is missing. Run scripts/setup_usbipd.sh first — it builds the USB/IP server this needs."
fi

# An install made before usbipd-mac.patch existed runs a usbipd that cannot program an
# FPGA (the attach fails, or programming stops part way), so refuse rather than fail later.
if ! git -C "$script_dir/../mac-tools/usbipd-mac" apply --reverse --check "$script_dir/usbipd-mac.patch" &> /dev/null; then
    f_fail "usbipd was built without this repo's fixes. Run scripts/setup_usbipd.sh once, then try again."
fi

# --- Startup confirmation with timeout ---

f_echo "Press Enter within 5 seconds to connect the JTAG cable."
f_echo "Doing nothing shuts down the usbipd daemon and exits."

if ! read -t 5 -r; then
    # Timeout: no input within 5 seconds
    if pgrep -qf "$usbipd_bin daemon"; then
        f_echo "Shutting down usbipd daemon..."
        pkill -f "$usbipd_bin daemon"
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
    candidate=$(grep -oE '(0x)?[0-9a-fA-F]{4}:(0x)?[0-9a-fA-F]{4}' <<< "$line")
    [[ -z "$candidate" ]] && continue
    # lowercased and stripped of any 0x prefix before matching: usbipd actually
    # prints plain lowercase %04x with no 0x prefix, but tolerate a 0x-prefixed
    # or uppercase form too, since a cable that silently "isn't found" because
    # of hex case would be miserable to debug
    candidate=${candidate:l}
    candidate=${candidate//0x/}
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

start_daemon() {
    f_echo "Starting usbipd daemon..."
    # usbipd-mac needs no root: it has no euid checks, port 3240 is unprivileged,
    # and macOS lets normal users open USB devices with no kernel driver. State lives in ~/.usbipd.
    "$usbipd_bin" daemon &> /tmp/usbipd-daemon.log &
    disown

    f_echo "Waiting for usbipd daemon to listen on port 3240..."
    for i in {1..10}; do
        nc -z localhost 3240 &> /dev/null && return
        sleep 1
    done
    f_fail "usbipd daemon never started listening on port 3240. Check /tmp/usbipd-daemon.log."
}

if pgrep -qf "$usbipd_bin daemon"; then
    f_echo "usbipd daemon already running"
else
    start_daemon
fi

container_running() {
    docker ps --format '{{.Names}}' | grep -qx "$container_name"
}

# The device attached for $busid inside the container, as "vid:pid", if any.
# `usbip port` prints "<local busid> -> usbip://<host>:3240/<remote busid>" per port.
attached_vidpid() {
    docker exec -i "$container_name" bash -s -- "$busid" "$usbip_bin_in_container" <<'INNER'
sysfs=$("$2" port 2> /dev/null | awk -v suffix="/$1" \
    'substr($0, length($0) - length(suffix) + 1) == suffix { print $1 }' | tail -1)
d="/sys/bus/usb/devices/$sysfs"
[[ -n "$sysfs" && -f "$d/idVendor" ]] && echo "$(cat "$d/idVendor"):$(cat "$d/idProduct")"
INNER
}

# Anything that drops the cable's connection (restarting the daemon, detaching a
# port) must not happen while hw_server is talking to it: a Platform Cable left
# mid-transaction stops answering until it is unplugged.
stop_hw_server() {
    if docker exec "$container_name" pgrep -x hw_server &> /dev/null; then
        f_echo "Stopping hw_server in $container_name first (Vivado relaunches it on Auto Connect)..."
        docker exec "$container_name" pkill -x hw_server
        sleep 2
    fi
}

# Re-running on a working attachment would only tear it down. It counts as current
# when the container sees the VID:PID the Mac sees now; after the cable re-enumerates
# from 0013 to 0008 the old attachment still shows 0013 and is replaced below.
if container_running && [[ "$(attached_vidpid)" == "$vidpid" ]]; then
    f_echo "$busid ($vidpid) is already attached inside $container_name; nothing to do."
    f_echo "This window will close in 5 seconds."
    sleep 5
    exit 0
fi

# --- Step 3: bind the device ---

bind_device() {
    f_echo "Binding $busid..."
    bind_output=$("$usbipd_bin" bind "$busid" 2>&1)
    bind_status=$?
    echo "$bind_output"
}

bind_device

# macOS sets no configuration on a vendor-class device it has no driver for (an
# unconfigured Platform Cable, 03fd:0013), so there are no interfaces to share.
# Selecting configuration 1 is the standard request any OS sends on enumeration;
# it changes nothing on the device that outlasts unplugging it.
if (( bind_status != 0 )) && [[ "$bind_output" == *"exposes no USB interfaces"* ]]; then
    f_echo "macOS left $busid unconfigured; selecting configuration 1..."
    if ! "$usb_python" - "$vid" "${vidpid#*:}" <<'PY'
import sys, usb1
vid, pid = (int(x, 16) for x in sys.argv[1:3])
with usb1.USBContext() as ctx:
    handle = ctx.openByVendorIDAndProductID(vid, pid)
    if handle is None:
        sys.exit("cannot open the device")
    if handle.getConfiguration() == 0:
        handle.setConfiguration(1)
    handle.close()
PY
    then
        f_fail "Could not select a configuration on $busid."
    fi
    sleep 1
    bind_device
fi

# bind refuses a device whose interface is held open, and doesn't recognise its own
# daemon as the holder. The daemon keeps the interface open once a client has
# attached, including after the cable re-enumerated from 0013 to 0008 underneath it.
# Restarting the daemon releases it; the old attachment is stale by then anyway.
daemon_pid=$(pgrep -f "$usbipd_bin daemon" | head -1)
if (( bind_status != 0 )) && [[ "$bind_output" == *"owned by"* ]] \
    && ioreg -r -c IOUSBHostInterface -l -w0 | grep -q "\"IOUserClientCreator\" = \"pid $daemon_pid, usbipd\""; then
    f_echo "The usbipd daemon itself holds $busid from an earlier attachment; restarting it..."
    container_running && stop_hw_server
    pkill -f "$usbipd_bin daemon"
    sleep 2
    start_daemon
    bind_device
fi

if (( bind_status != 0 )); then
    f_fail "Failed to bind $busid (see message above)."
fi

# --- Step 4: make sure the container is running ---

if ! container_running; then
    f_fail "$container_name is not running. Start it with start_container.sh first."
fi

# --- Step 5: attach the device inside the container ---

# vhci_hcd lives in Docker's VM kernel, not in the container, so an attachment
# outlives the container that made it and survives a daemon restart as a dead port.
# Left in place, the next attach gets a second port and Step 6 could pick the dead one.
# `usbip port` prints "<local busid> -> usbip://<host>:3240/<remote busid>" per port.
stale_ports=($(docker exec "$container_name" "$usbip_bin_in_container" port 2> /dev/null \
    | awk -v suffix="/$busid" '
        /^Port / { port = $2 + 0 }
        substr($0, length($0) - length(suffix) + 1) == suffix { print port }'))
(( $#stale_ports )) && stop_hw_server
for port in $stale_ports; do
    f_echo "Detaching earlier attachment of $busid on port $port..."
    docker exec -u root "$container_name" "$usbip_bin_in_container" detach -p "$port"
done

f_echo "Attaching $busid inside $container_name..."
if ! docker exec "$container_name" "$usbip_bin_in_container" attach -r host.docker.internal -b "$busid"; then
    f_fail "usbip attach failed inside the container."
fi

# --- Step 6: fixups a udev daemon would normally handle ---

f_echo "Locating the device node inside the container..."
# Found through the port just attached for this busid rather than by VID:PID, so
# another attachment of the same cable model can't be picked. Retries for up to
# ~10s: the kernel may not have enumerated the device immediately after attach.
device_info=$(docker exec -i -u root "$container_name" bash -s -- "$busid" "$usbip_bin_in_container" <<'INNER'
busid="$1"
usbip="$2"
for i in $(seq 1 10); do
    sysfs=$("$usbip" port 2> /dev/null | awk -v suffix="/$busid" \
        'substr($0, length($0) - length(suffix) + 1) == suffix { print $1 }' | tail -1)
    d="/sys/bus/usb/devices/$sysfs"
    if [[ -n "$sysfs" && -f "$d/busnum" && -f "$d/devnum" ]]; then
        node=$(printf "/dev/bus/usb/%03d/%03d" "$(cat "$d/busnum")" "$(cat "$d/devnum")")
        if [[ -e "$node" ]]; then
            echo "$node $sysfs"
            exit 0
        fi
    fi
    sleep 1
done
exit 1
INNER
)

if [[ -z "$device_info" ]]; then
    f_fail "Could not find the attached $busid ($vidpid) in the container after attach."
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

if [[ "$vid" == "0403" ]]; then
    f_echo "Unbinding kernel ftdi_sio driver from interfaces 0 and 1 (as 52-xilinx-ftdi-usb.rules does)..."
    docker exec -u root "$container_name" bash -c "
        echo -n '${sysfs_id}:1.0' > /sys/bus/usb/drivers/ftdi_sio/unbind 2> /dev/null
        echo -n '${sysfs_id}:1.1' > /sys/bus/usb/drivers/ftdi_sio/unbind 2> /dev/null
        true
    "
fi

# --- Step 7: verify and report ---

f_echo "Verifying..."
f_echo "Device node: $device_node (sysfs $sysfs_id)"
docker exec "$container_name" bash -c "ls -l '$device_node'"

if [[ "$vidpid" == "03fd:0013" ]]; then
    f_echo "This is an unconfigured Xilinx Platform Cable USB II (03fd:0013), with no firmware loaded yet."
    f_echo "No manual firmware step is needed: hw_server loads the firmware itself (RAM only, same as"
    f_echo "on any Windows/Linux PC) as soon as it sees the cable -- right away if Vivado's Hardware Manager"
    f_echo "is connected, otherwise on Open Target -> Auto Connect."
    f_echo "The cable then comes back as 03fd:0008 and this USB/IP attachment goes stale."
    f_echo "Run this script again then: it clears the stale attachment and attaches the 0008 cable."
    f_echo "If the cable vanishes from the Mac entirely after that, macOS may have locked the USB-C port:"
    f_echo "don't unplug the adapter yet (that resets the cable back to 0013) -- tell Claude/check instead."
    f_echo "Press Enter to close this window."
    read -r
    exit 0
else
    f_echo "JTAG cable connected and ready."
    f_echo "This window will close in 5 seconds."
    sleep 5
    exit 0
fi
