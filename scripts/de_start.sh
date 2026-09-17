#!/bin/bash

# This script is run whenever the desktop environment has started.
# (with normal user privileges).

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_linux

export LD_PRELOAD="/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libgdk-x11-2.0.so.0"

# if Vivado is installed
if [ -d "/home/user/Xilinx" ]
then
	# USB/IP: cable is attached directly to this container's USB bus,
	# so hw_server searches for it locally instead of via xvcd/XVC.
	/home/user/Xilinx/*/Vivado/bin/hw_server &
	/home/user/Xilinx/*/Vivado/settings64.sh
	/home/user/Xilinx/*/Vivado/bin/vivado
else
	f_echo "The installation is incomplete."
	wait_for_user_input
fi