#!/bin/zsh

# Sets up the host side of JTAG forwarding: builds usbipd-mac (the USB/IP server)
# with this repo's fixes, and the python environment jtag_connect.sh uses for USB.
# Run by setup.sh; an existing install can run it on its own to pick up changes.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

if ! which swift &> /dev/null
then
	f_echo "swift is required to build usbipd-mac (the USB/IP server used for JTAG forwarding)."
	f_echo "Install the Xcode Command Line Tools with 'xcode-select --install' and run this script again."
	exit 1
fi

if [ ! -d "$script_dir/../mac-tools/usbipd-mac" ]
then
	f_echo "Cloning usbipd-mac..."
	if ! git clone https://github.com/beriberikix/usbipd-mac "$script_dir/../mac-tools/usbipd-mac"
	then
		f_echo "Error cloning usbipd-mac."
		exit 1
	fi
fi

# usbipd-mac needs fixes before a Platform Cable can program an FPGA through it; see
# the top of usbipd-mac.patch. Pinned to the commit the patch was tested against, and
# skipped when already applied so rerunning this script is harmless.
usbipd_patch="$script_dir/usbipd-mac.patch"
if ! (cd "$script_dir/../mac-tools/usbipd-mac" && git apply --reverse --check "$usbipd_patch" &> /dev/null)
then
	f_echo "Applying fixes to usbipd-mac..."
	if ! (cd "$script_dir/../mac-tools/usbipd-mac" && git checkout -q 1c2ab4594653db5859d6773bdd010303a641e98e && git apply "$usbipd_patch")
	then
		f_echo "Error applying usbipd-mac.patch. Remove the mac-tools folder and run this script again."
		exit 1
	fi
fi

f_echo "Building usbipd-mac..."
if ! (cd "$script_dir/../mac-tools/usbipd-mac" && swift build -c release)
then
	# Swift's module cache records absolute paths, so a build made before this folder
	# was moved fails with "PCH was compiled with module cache path ...".
	f_echo "Retrying with a fresh module cache..."
	rm -rf "$script_dir/../mac-tools/usbipd-mac/.build/"*/release/ModuleCache
fi
if ! (cd "$script_dir/../mac-tools/usbipd-mac" && swift build -c release)
then
	f_echo "Error building usbipd-mac. Check the output above."
	exit 1
fi

# An unconfigured Platform Cable (03fd:0013) is left without a USB configuration by
# macOS, so usbipd has nothing to share until jtag_connect.sh selects one. It does
# that with python's libusb1 module, which needs the libusb library from Homebrew.
usb_venv="$script_dir/../mac-tools/usb-venv"
if [ ! -x "$usb_venv/bin/python3" ]
then
	f_echo "Setting up the python environment jtag_connect.sh uses for USB..."
	if ! (python3 -m venv "$usb_venv" && "$usb_venv/bin/pip" install -q libusb1)
	then
		f_echo "Error setting up $usb_venv."
		exit 1
	fi
fi
if ! "$usb_venv/bin/python3" -c "import usb1; usb1.USBContext().open()" &> /dev/null
then
	f_echo "The libusb library is missing. Install it with 'brew install libusb' and run this script again."
	exit 1
fi
