#!/bin/zsh

# Sets up the host side of JTAG forwarding: builds usbipd-mac (the USB/IP server)
# with this repo's fixes, and the python environment jtag_connect.sh uses for USB.
# Run by setup.sh; an existing install can run it on its own to pick up changes.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

if ! which swift &> /dev/null
then
	f_fail "Xcode Command Line Tools are missing (needed to build the JTAG forwarding server)." \
		"Run: xcode-select --install   — then run setup.sh again."
fi

if [ ! -d "$script_dir/../mac-tools/usbipd-mac" ]
then
	f_step "Downloading usbipd-mac (the USB/IP server)..."
	if ! git clone -q https://github.com/beriberikix/usbipd-mac "$script_dir/../mac-tools/usbipd-mac"
	then
		f_fail "Could not download usbipd-mac. Check the internet connection and run this again."
	fi
fi

# usbipd-mac needs fixes before a Platform Cable can program an FPGA through it; see
# the top of usbipd-mac.patch. Pinned to the commit the patch was tested against, and
# skipped when already applied so rerunning this script is harmless.
usbipd_patch="$script_dir/usbipd-mac.patch"
if ! (cd "$script_dir/../mac-tools/usbipd-mac" && git apply --reverse --check "$usbipd_patch" &> /dev/null)
then
	f_step "Applying this repo's fixes to usbipd-mac..."
	if ! (cd "$script_dir/../mac-tools/usbipd-mac" && git checkout -q 1c2ab4594653db5859d6773bdd010303a641e98e && git apply "$usbipd_patch")
	then
		f_fail "Could not apply usbipd-mac.patch." \
			"Delete the mac-tools folder and run this again."
	fi
fi

f_step "Building usbipd-mac (a few minutes the first time)..."
if ! (cd "$script_dir/../mac-tools/usbipd-mac" && swift build -c release)
then
	# Swift's module cache records absolute paths, so a build made before this folder
	# was moved fails with "PCH was compiled with module cache path ...".
	f_warn "Build failed. Retrying with a fresh module cache..."
	rm -rf "$script_dir/../mac-tools/usbipd-mac/.build/"*/release/ModuleCache
fi
if ! (cd "$script_dir/../mac-tools/usbipd-mac" && swift build -c release)
then
	f_fail "Building usbipd-mac failed (see the lines above)."
fi

# An unconfigured Platform Cable (03fd:0013) is left without a USB configuration by
# macOS, so usbipd has nothing to share until jtag_connect.sh selects one. It does
# that with python's libusb1 module, which needs the libusb library from Homebrew.
usb_venv="$script_dir/../mac-tools/usb-venv"
if [ ! -x "$usb_venv/bin/python3" ]
then
	f_step "Setting up the Python environment used to talk to the cable..."
	if ! (python3 -m venv "$usb_venv" && "$usb_venv/bin/pip" install -q libusb1)
	then
		f_fail "Could not set up $usb_venv."
	fi
fi
if ! "$usb_venv/bin/python3" -c "import usb1; usb1.USBContext().open()" &> /dev/null
then
	f_fail "The libusb library is missing." \
		"Run: brew install libusb   — then run setup.sh again."
fi
