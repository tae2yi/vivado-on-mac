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
# how long to wait for an unconfigured Platform Cable (03fd:0013) to come back as 03fd:0008
reenum_timeout=90

# Output helpers. One symbol and colour per kind of line, so the state can be
# read at a glance:  ▶ working on it   ✔ done   ⚠ heads-up   ✖ failed
c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_dim=$'\e[2m'
c_red=$'\e[1;31m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_cyan=$'\e[1;36m'
c_rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

f_step() { print -r -- "${c_cyan}▶ $1${c_reset}"; }
f_ok()   { print -r -- "${c_green}✔ $1${c_reset}"; }
f_warn() { print -r -- "${c_yellow}⚠ $1${c_reset}"; }
f_info() { print -r -- "${c_dim}  $1${c_reset}"; }

# A boxed-off message for the things that must not be missed: f_banner <colour> <title> [line...]
f_banner() {
    local color=$1 title=$2 line
    shift 2
    print -r -- ""
    print -r -- "${color}${c_rule}${c_reset}"
    print -r -- "${color}┃ ${title}${c_reset}"
    for line in "$@"; do
        print -r -- "${color}┃${c_reset} ${c_bold}${line}${c_reset}"
    done
    print -r -- "${color}${c_rule}${c_reset}"
    print -r -- ""
}

f_close_in_5() {
    f_info "This window closes in 5 seconds."
    sleep 5
}

# Prints an error message, waits for the user to read it (the window may have
# been opened by double-clicking an alias, with nothing else on screen to
# explain what happened), then exits with status 1.
f_fail() {
    f_banner "$c_red" "✖ FAILED" "$@"
    f_info "Press Enter to close this window."
    read -r
    exit 1
}

if [[ ! -x "$usbipd_bin" || ! -x "$usb_python" ]]; then
    f_fail "usbipd is missing." \
        "Run scripts/setup_usbipd.sh first: it builds the USB/IP server this needs."
fi

# An install made before usbipd-mac.patch existed runs a usbipd that cannot program an
# FPGA (the attach fails, or programming stops part way), so refuse rather than fail later.
if ! git -C "$script_dir/../mac-tools/usbipd-mac" apply --reverse --check "$script_dir/usbipd-mac.patch" &> /dev/null; then
    f_fail "usbipd was built without this repo's fixes." \
        "Run scripts/setup_usbipd.sh once, then try again."
fi

# --- Startup confirmation with timeout ---

# Skipped when the script re-runs itself after the cable re-enumerated (see Step 7).
if [[ -z "$JTAG_CONNECT_RERUN" ]]; then
    f_banner "$c_cyan" "JTAG CONNECT" \
        "Press Enter within 5 seconds  →  connect the JTAG cable" \
        "Do nothing                    →  stop the usbipd daemon and exit"

    if ! read -t 5 -r; then
        # Timeout: no input within 5 seconds
        if pgrep -qf "$usbipd_bin daemon"; then
            f_step "Shutting down usbipd daemon..."
            pkill -f "$usbipd_bin daemon"
            f_ok "usbipd daemon stopped."
        else
            f_ok "No usbipd daemon running. Nothing to stop."
        fi
        f_close_in_5
        exit 0
    fi
fi

# --- Step 1: find the cable ---

f_step "Looking for a JTAG cable on this Mac..."
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
    f_warn "No supported JTAG cable found. USB devices this Mac sees:"
    print -r -- "${c_dim}$list_output${c_reset}"
    f_fail "No JTAG cable found." \
        "1. Plug the JTAG cable (and its USB-C adapter) into the Mac." \
        "2. Run \"Connect JTAG.command\" again." \
        "Cable LED on but still not found? Unplug the ADAPTER at the Mac and plug it back in."
fi

case $vidpid in
    03fd:0013) f_ok "Found cable $vidpid (no firmware yet) at busid $busid" ;;
    *)         f_ok "Found cable $vidpid at busid $busid" ;;
esac

# --- Step 2: make sure the usbipd daemon is running and listening ---

start_daemon() {
    f_step "Starting usbipd daemon..."
    # usbipd-mac needs no root: it has no euid checks, port 3240 is unprivileged,
    # and macOS lets normal users open USB devices with no kernel driver. State lives in ~/.usbipd.
    "$usbipd_bin" daemon &> /tmp/usbipd-daemon.log &
    disown

    for i in {1..10}; do
        if nc -z localhost 3240 &> /dev/null; then
            f_ok "usbipd daemon running"
            return
        fi
        sleep 1
    done
    f_fail "The usbipd daemon did not start (port 3240)." "Details: /tmp/usbipd-daemon.log"
}

if pgrep -qf "$usbipd_bin daemon"; then
    f_ok "usbipd daemon already running"
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
        f_step "Stopping hw_server first (it must not be talking to the cable while it is re-attached)..."
        docker exec "$container_name" pkill -x hw_server
        sleep 2
    fi
}

# Starts hw_server the way Vivado's Auto Connect would (default port 3121), so
# Auto Connect finds a server that already sees the cable instead of launching
# its own. Having Vivado launch it and then stopping it mid-Auto-Connect, as the
# 0013 -> 0008 re-attach has to, makes Vivado report "out-of-date hw_server".
start_hw_server() {
    docker exec "$container_name" pgrep -x hw_server &> /dev/null && return
    f_step "Starting hw_server in $container_name..."
    docker exec -d -u user -e HOME=/home/user "$container_name" sh -c \
        'exec "$(ls -d /home/user/Xilinx/*/Vivado/bin/hw_server /home/user/Xilinx/Vivado/*/bin/hw_server 2> /dev/null | tail -1)"'
    sleep 3
    if docker exec "$container_name" pgrep -x hw_server &> /dev/null; then
        f_ok "hw_server running"
    else
        f_warn "hw_server did not start; Vivado will launch its own on Auto Connect."
    fi
}

# hw_server only scans for cables, and so only loads a Platform Cable's firmware,
# once a client has connected and asked it for its JTAG targets; started on its
# own it leaves the cable at 03fd:0013 indefinitely. xsdb, installed next to
# hw_server, is that client here. It runs detached and exits by itself.
poke_hw_server() {
    docker exec -d -u user -e HOME=/home/user "$container_name" sh -c '
        xsdb=$(ls -d /home/user/Xilinx/*/Vivado/bin/xsdb /home/user/Xilinx/Vivado/*/bin/xsdb 2> /dev/null | tail -1)
        printf "connect -url tcp:localhost:3121\njtag targets\nafter 5000\n" > /tmp/jtag_connect_poke.tcl
        exec "$xsdb" /tmp/jtag_connect_poke.tcl > /dev/null 2>&1'
}

# Re-running on a working attachment would only tear it down. It counts as current
# when the container sees the VID:PID the Mac sees now; after the cable re-enumerates
# from 0013 to 0008 the old attachment still shows 0013 and is replaced below.
if container_running && [[ "$(attached_vidpid)" == "$vidpid" ]]; then
    f_banner "$c_green" "✔ ALREADY CONNECTED — nothing to do" \
        "Cable $vidpid is attached to $container_name." \
        "In Vivado:  Open Target  →  Auto Connect"
    f_close_in_5
    exit 0
fi

# --- Step 3: bind the device ---

bind_device() {
    f_step "Sharing the cable over USB/IP (bind $busid)..."
    bind_output=$("$usbipd_bin" bind "$busid" 2>&1)
    bind_status=$?
}

bind_device

# macOS sets no configuration on a vendor-class device it has no driver for (an
# unconfigured Platform Cable, 03fd:0013), so there are no interfaces to share.
# Selecting the device's first configuration is the standard request any OS sends
# on enumeration; it changes nothing on the device that outlasts unplugging it.
if (( bind_status != 0 )) && [[ "$bind_output" == *"exposes no USB interfaces"* ]]; then
    f_info "macOS left the cable unconfigured (normal for 0013); selecting its USB configuration..."
    if ! "$usb_python" - "$vid" "${vidpid#*:}" <<'PY'
import sys, usb1
vid, pid = (int(x, 16) for x in sys.argv[1:3])
with usb1.USBContext() as ctx:
    handle = ctx.openByVendorIDAndProductID(vid, pid)
    if handle is None:
        sys.exit("cannot open the device")
    if handle.getConfiguration() == 0:
        # read from the descriptor rather than assumed to be 1, which it almost
        # always is but doesn't have to be
        handle.setConfiguration(handle.getDevice()[0].getConfigurationValue())
    handle.close()
PY
    then
        f_fail "Could not select a USB configuration on $busid."
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
    f_info "The usbipd daemon still holds the cable from an earlier attachment; restarting it..."
    container_running && stop_hw_server
    pkill -f "$usbipd_bin daemon"
    sleep 2
    start_daemon
    bind_device
fi

if (( bind_status != 0 )); then
    print -r -- "${c_dim}$bind_output${c_reset}"
    f_fail "Could not share the cable (bind $busid failed)." "usbipd's own message is shown above."
fi
f_ok "Cable shared"

# --- Step 4: make sure the container is running ---

if ! container_running; then
    f_fail "The Vivado container is not running." "Start it first with \"Start Vivado.command\", then run \"Connect JTAG.command\" again."
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
    f_step "Removing the old (dead) attachment on port $port..."
    docker exec -u root "$container_name" "$usbip_bin_in_container" detach -p "$port" &> /dev/null
done

f_step "Attaching the cable inside $container_name..."
# Retried: for a few seconds after the cable is plugged in (or re-enumerates) the
# daemon has not picked the new device up yet and refuses with "Request Failed".
for attempt in {1..5}; do
    attach_output=$(docker exec "$container_name" "$usbip_bin_in_container" attach -r host.docker.internal -b "$busid" 2>&1) && break
    if (( attempt == 5 )); then
        print -r -- "${c_dim}$attach_output${c_reset}"
        f_fail "Could not attach the cable inside the container." "usbip's own message is shown above."
    fi
    f_info "The daemon is not ready for this cable yet; retrying ($attempt/4)..."
    sleep 2
done

# --- Step 6: fixups a udev daemon would normally handle ---

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
if ! docker exec -u root "$container_name" chmod 666 "$device_node"; then
    f_fail "Failed to chmod $device_node."
fi

if [[ "$vid" == "0403" ]]; then
    f_info "Unbinding kernel ftdi_sio driver from interfaces 0 and 1 (as 52-xilinx-ftdi-usb.rules does)..."
    docker exec -u root "$container_name" bash -c "
        echo -n '${sysfs_id}:1.0' > /sys/bus/usb/drivers/ftdi_sio/unbind 2> /dev/null
        echo -n '${sysfs_id}:1.1' > /sys/bus/usb/drivers/ftdi_sio/unbind 2> /dev/null
        true
    "
fi

# --- Step 7: verify and report ---

f_ok "Cable attached: $vidpid at $device_node"

if [[ "$vidpid" == "03fd:0013" ]]; then
    # Wait for that re-enumeration and re-run, so the stale 0013 attachment is
    # replaced by the 0008 cable without a second manual run.
    start_hw_server
    f_banner "$c_yellow" "⚠ NOT READY YET — please wait (about 30 seconds)" \
        "The cable has no firmware yet (03fd:0013). hw_server is loading it now." \
        "Do NOT press Auto Connect in Vivado until you see the green READY box."
    # The firmware load re-enumerates the cable twice, a few seconds apart, and it
    # shows as 03fd:0008 in between; only a 0008 that stays put is the final one.
    stable=0
    for i in {1..$reenum_timeout}; do
        if "$usbipd_bin" list 2> /dev/null | grep -qi '03fd:0008'; then
            (( ++stable ))
            wait_state="firmware loaded, checking it stays put ($stable/8)"
        else
            stable=0
            wait_state="loading firmware"
        fi
        # asked again every 30 s in case the first request came before hw_server was listening
        (( i % 30 == 1 && stable == 0 )) && poke_hw_server
        print -n -r -- $'\r\e[K'"${c_yellow}⏳ ${i}s  ${wait_state}...${c_reset}"
        if (( stable >= 8 )); then
            print -r -- ""
            f_ok "Firmware loaded: the cable is now 03fd:0008"
            f_step "Re-attaching the cable with its new identity..."
            JTAG_CONNECT_RERUN=1 exec zsh "$0"
        fi
        sleep 1
    done
    print -r -- ""

    f_fail "The cable did not finish loading its firmware in $reenum_timeout seconds." \
        "Run \"Connect JTAG.command\" again." \
        "Still failing? Unplug the USB-C ADAPTER at the Mac, plug it back in, run \"Connect JTAG.command\"."
else
    start_hw_server
    f_banner "$c_green" "✔ READY — JTAG cable connected" \
        "Now in Vivado:  Open Target  →  Auto Connect" \
        "When you are done: run \"Connect JTAG.command\" again and just wait 5 seconds."
    f_close_in_5
    exit 0
fi
