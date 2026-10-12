#!/bin/bash

# This runs the Vivado installer in batch mode.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_linux


install_bin_path=$(tr -d "\n\r\t " < "/home/user/scripts/install_bin")

vivado_version="202610"

f_echo "Choosing modules to install..."
if ! bash "/home/user/scripts/select_modules.sh" "/home/user/scripts/install_configs/${vivado_version}.txt" "/home/user/scripts/install_configs/${vivado_version}.selected.txt"
then
	f_echo "Module selection failed."
	exit 1
fi

f_echo "Extracting installer"
eval "$install_bin_path --target /home/user/installer --noexec"

f_echo "Log into your Xilinx account to download the necessary files."
while ! /home/user/installer/xsetup -b AuthTokenGen
do
	f_echo "Your account information seems to be wrong. Please try logging in again."
	sleep 1
done

f_echo "start offline setup."
eula_args="XilinxEULA,3rdPartyEULA"

# Check if the version is 202110 to include WebTalk terms
if [ "$vivado_version" = "202110" ]; then
    eula_args="${eula_args},WebTalkTerms"
    f_echo "Note: The 2021.1 version enables WebTalk data collection and agrees automatically to the corresponding terms."
    f_echo "For more information, see: https://docs.amd.com/r/2021.1-English/ug973-vivado-release-notes-install-license/WebTalk-Participation"
    wait_for_user_input
fi

if /home/user/installer/xsetup -c "/home/user/scripts/install_configs/${vivado_version}.selected.txt" -b Install -a "${eula_args}"
then
    f_echo "Vivado was successfully installed."

    # sudo strips LD_PRELOAD, and only de_start.sh's own process tree re-exports
    # it, so Desktop/Start Menu launchers crash with "realloc(): invalid
    # pointer" unless LD_PRELOAD is baked directly into their Exec= line.
    ld_preload_libs="/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libgdk-x11-2.0.so.0"
    for f in /home/user/Desktop/*.desktop /home/user/.local/share/applications/*.desktop
    do
        [ -f "$f" ] || continue
        grep -q "bin/vivado" "$f" || continue
        grep -q "LD_PRELOAD" "$f" && continue
        sed -i "s|^Exec=|Exec=env LD_PRELOAD=\"${ld_preload_libs}\" |" "$f"
    done
    f_echo "Run start_container.sh to launch it."
else
    f_echo "An error occurred during installation. Please run cleanup.sh and try again."
    exit 1
fi