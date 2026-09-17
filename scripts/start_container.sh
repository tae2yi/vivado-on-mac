#!/bin/zsh

# starts the Docker container; USB access for JTAG comes via USB/IP
# (usbipd-mac on the host + usbip client inside the container), not xvcd.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

# this is called when the container stops or ctrl+c is hit
function stop_container {
    docker kill vivado_container > /dev/null 2>&1
    f_echo "Stopped Docker container"
    exit 0
}
trap 'stop_container' INT

# Make sure everything is setup to run the container
start_docker
if [[ $(docker ps) == *vivado_container* ]]
then
    f_echo "There is already an instance of the container running."
    exit 1
fi

# run container
# Reuse the MAC address generated during setup.sh so the Vivado license Host
# ID (derived from it) stays stable across restarts.
container_mac=$(tr -d "\n\r\t " < "$script_dir/mac_address")
# --privileged + /dev/bus/usb so the container can see the USB/IP-attached
# JTAG cable, including one attached after the container has already started.
docker run --init --rm --privileged -v /dev/bus/usb:/dev/bus/usb --name vivado_container --mac-address="$container_mac" --mount type=bind,source="$script_dir/..",target="/home/user" -p 127.0.0.1:5901:5901 --platform linux/amd64 x64-linux sudo -H -u user bash /home/user/scripts/linux_start.sh &
f_echo "Started container"
sleep 7
f_echo "Starting VNC viewer"
vncpass=$( tr -d "\n\r\t " < "$script_dir/vncpasswd" )
osascript -e "tell application \"Screen Sharing\" to GetURL \"vnc://user:$vncpass@localhost:5901\""
wait