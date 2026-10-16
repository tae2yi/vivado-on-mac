#!/bin/zsh

# Initial setup on host (macOS) side

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
# Make sure that the script is run in macOS and not the Docker container
validate_macos

repo_dir=$(dirname "$script_dir")
total_stages=7

# Vivado versions this repo has an install catalog for (install_configs/<yyyy><v>0.txt)
supported_versions=(2025.2 2026.1)

# Prints the Vivado version of a web installer .bin (e.g. 2026.1), or nothing.
# The makeself header records the build's image name, which carries the version
# even if the file was renamed; the file name is the fallback.
function detect_vivado_version {
	local v
	v=$(head -c 20000 "$1" 2> /dev/null | LC_ALL=C grep -aoE 'Unified_SDI_20[0-9]{2}\.[0-9]' | head -1)
	v=${v#Unified_SDI_}
	if [[ -z "$v" ]]
	then
		v=$(basename "$1" | grep -oE '_20[0-9]{2}\.[0-9]_' | head -1 | tr -d _)
	fi
	print -r -- "$v"
}

f_banner "$c_cyan" "Vivado on Apple Silicon — setup" \
	"This installs Vivado into this folder, inside a Docker container." \
	"It takes 1-2 hours, mostly downloading. Keep the Mac awake and plugged in." \
	"Lines starting with ${c_magenta}➜${c_reset} need you to do something."

# --- Stage 1 -----------------------------------------------------------------
f_stage 1 $total_stages "Checking this Mac"

if [[ "$current_user" == "root" ]]
then
	f_fail "Do not run this script as root (no sudo)." \
		"Run it as yourself: zsh ./scripts/setup.sh"
fi

if [[ "$repo_dir" == *" "* ]]
then
	f_fail "This folder's path contains a space:" \
		"  $repo_dir" \
		"Vivado's tools break on such paths. Move the folder somewhere like" \
		"  ~/Documents/vivado-on-mac" \
		"and run setup.sh from there."
fi

if [ -d "$repo_dir/Xilinx" ]
then
	f_fail "Vivado is already installed in this folder (the Xilinx folder exists)." \
		"To start it, double-click \"Start Vivado.command\"." \
		"To reinstall, run scripts/cleanup.sh first (it keeps a copy of your license)."
fi

validate_internet
f_ok "macOS, user account, folder path and internet connection look fine."

f_info "Continuing means you agree to:"
f_info " - AMD's EULAs (they are inside the installer .bin)"
f_info " - Apple's license for Rosetta 2, if it gets installed"
f_ask "Continue? [Y/n]"
read user_consent
case $user_consent in
""|[yY]|[yY][eE]*)
	;;
*)
	f_warn "Setup cancelled. Nothing was changed."
	exit 1
	;;
esac

# --- Stage 2 -----------------------------------------------------------------
f_stage 2 $total_stages "Rosetta (runs Intel Linux programs on Apple Silicon)"

if [[ "$(uname -m)" == "x86_64" ]]; then
	f_ok "This Mac is Intel-based, so Rosetta is not needed."
elif arch -arch x86_64 uname -m > /dev/null 2>&1; then
	f_ok "Rosetta is already installed."
else
	f_step "Installing Rosetta..."
	if ! softwareupdate --install-rosetta --agree-to-license; then
		f_fail "Rosetta could not be installed." \
			"Run this in Terminal, then run setup.sh again:" \
			"  softwareupdate --install-rosetta --agree-to-license"
	fi
	f_ok "Rosetta installed."
fi

# --- Stage 3 -----------------------------------------------------------------
f_stage 3 $total_stages "Vivado installer file"

installation_binary=""
# Offer the installer if exactly one is already sitting in this folder
found_bins=("$repo_dir"/*.bin(N))
if (( ${#found_bins} == 1 ))
then
	f_ok "Found ${found_bins[1]:t}"
	f_ask "Use this file? [Y/n]"
	read use_found
	case $use_found in
	""|[yY]|[yY][eE]*) installation_binary=${found_bins[1]} ;;
	esac
fi

while [[ -z "$installation_binary" ]]
do
	f_ask "Drag the Vivado installer (the ..._Lin64.bin file) into this window, then press Enter:"
	if ! read -r dropped
	then
		f_fail "No file was given."
	fi
	# Terminal pastes a dragged file as a path with backslash-escaped spaces and a
	# trailing space; some apps quote it instead
	dropped=$(printf '%s' "$dropped" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\\\(.\)/\1/g' -e "s/^[\"']//" -e "s/[\"']\$//")
	if [[ ! -f "$dropped" ]]
	then
		f_warn "No file found at: $dropped"
		continue
	fi
	if [[ "$dropped" != *.bin ]]
	then
		f_warn "That is not a .bin file. Use the Linux Self Extracting Web Installer (.bin)."
		continue
	fi
	installation_binary=$dropped
done

# The container only sees this folder, so the installer has to be inside it
if [[ "$installation_binary" != $repo_dir/* ]]
then
	f_warn "The installer has to be inside this folder for the container to reach it."
	f_ask "Move ${installation_binary:t} into $repo_dir now? [Y/n]"
	read move_it
	case $move_it in
	""|[yY]|[yY][eE]*)
		if ! mv "$installation_binary" "$repo_dir/"
		then
			f_fail "Could not move the file. Move it into $repo_dir yourself and run setup.sh again."
		fi
		installation_binary="$repo_dir/${installation_binary:t}"
		f_ok "Moved."
		;;
	*)
		f_fail "Move the installer into $repo_dir yourself and run setup.sh again."
		;;
	esac
fi

# The container reads the path back from a file with whitespace stripped
if [[ "${installation_binary:t}" == *[[:space:]]* ]]
then
	renamed="$repo_dir/${${installation_binary:t}//[[:space:]]/_}"
	if ! mv "$installation_binary" "$renamed"
	then
		f_fail "Could not rename ${installation_binary:t}. Remove the spaces from its name and run setup.sh again."
	fi
	installation_binary=$renamed
	f_ok "Renamed it to ${installation_binary:t} (file names with spaces break the installer)."
fi

vivado_version=$(detect_vivado_version "$installation_binary")
if [[ -z "$vivado_version" ]]
then
	f_warn "Could not tell which Vivado version this installer is."
	f_ask "Which version is it? Type one of: ${supported_versions[*]}"
	read -r vivado_version
fi
if (( ! ${supported_versions[(Ie)$vivado_version]} ))
then
	f_fail "Vivado ${vivado_version:-(unknown)} is not supported." \
		"Supported versions: ${supported_versions[*]}" \
		"Download one of those from AMD's site (see the README's Quick start)."
fi
f_ok "Vivado $vivado_version installer: ${installation_binary:t}"

# The container reads these two files: where the installer is, and which version
install_bin_path="/home/user${installation_binary#$repo_dir}"
echo -n "$install_bin_path" > "$script_dir/install_bin"
echo -n "$vivado_version" > "$script_dir/vivado_version"

# Make the user own the whole folder
if ! chown -R $current_user "$repo_dir" 2> /dev/null
then
	f_ask "Your Mac password is needed to make you the owner of this folder:"
	if ! sudo chown -R $current_user "$repo_dir"
	then
		f_fail "Could not make $current_user the owner of $repo_dir."
	fi
fi

if ! chmod +x "$script_dir"/*.sh "$installation_binary"
then
	f_fail "Could not make the scripts executable."
fi

# --- Stage 4 -----------------------------------------------------------------
f_stage 4 $total_stages "JTAG cable forwarding tools (USB/IP)"

# Independent of the Vivado installer, so do it before the long container build below.
if ! zsh "$script_dir/setup_usbipd.sh"
then
	exit 1
fi
f_ok "JTAG forwarding tools are ready."

# --- Stage 5 -----------------------------------------------------------------
f_stage 5 $total_stages "Docker"

start_docker

# Attempt to enable Rosetta and set swap to at least 4GiB in Docker
"$script_dir/configure_docker.sh"

if ! "$script_dir/gen_image.sh"
then
	exit 1
fi

# --- Stage 6 -----------------------------------------------------------------
f_stage 6 $total_stages "Container settings"

f_info "Screen resolution of Vivado's desktop. Higher values make text smaller."
f_info "You can change it later in scripts/vnc_resolution."
f_ask "Press Enter for $vnc_default_resolution, or type another (e.g. 2560x1440):"
read resolution
if [[ $resolution =~ "^[0-9]+x[0-9]+$" ]]
then
	echo "$resolution" > "$script_dir/vnc_resolution"
else
	resolution=$vnc_default_resolution
	echo "$vnc_default_resolution" > "$script_dir/vnc_resolution"
fi
f_ok "Resolution: $resolution"

# copy de_start.desktop autostart file
mkdir -p "$repo_dir/.config/autostart"
cp "$script_dir/de_start.desktop" "$repo_dir/.config/autostart/de_start.desktop"
mkdir -p "$repo_dir/Desktop"

# Generate a random, locally-administered MAC address for the container and
# pin it via --mac-address, so it stays the same across container restarts
# (Docker's default bridge network otherwise doesn't guarantee a stable MAC
# for --rm containers). This matters because the Vivado license Host ID is
# derived from this MAC. Generated once per install rather than hardcoded,
# so that different installs/users don't all end up with the same Host ID.
if [ ! -f "$script_dir/mac_address" ]
then
	random_mac=$(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
	echo "$random_mac" > "$script_dir/mac_address"
fi
container_mac=$(tr -d "\n\r\t " < "$script_dir/mac_address")
f_ok "Container MAC address (your license Host ID): $container_mac"

# --- Stage 7 -----------------------------------------------------------------
f_stage 7 $total_stages "Installing Vivado $vivado_version (inside the container)"

docker run --init -it --rm --name vivado_container --mac-address="$container_mac" --mount type=bind,source="$repo_dir",target="/home/user" -p 127.0.0.1:5901:5901 --platform linux/amd64 x64-linux sudo -H -u user bash /home/user/scripts/install_vivado.sh
