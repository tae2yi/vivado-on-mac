#!/bin/bash

# This runs the Vivado installer in batch mode.

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_linux


install_bin_path=$(tr -d "\n\r\t " < "/home/user/scripts/install_bin")

# Written by setup.sh from the installer's own header, e.g. 2026.1
vivado_version=$(tr -d "\n\r\t " < "/home/user/scripts/vivado_version")
# install_configs/ names catalogs as yyyyv0, e.g. 2026.1 -> 202610
config_name="${vivado_version/./}0"
catalog="/home/user/scripts/install_configs/${config_name}.txt"
selection="/home/user/scripts/install_configs/${config_name}.selected.txt"

if [ ! -f "$catalog" ]
then
	f_fail "No install catalog for Vivado $vivado_version ($catalog)."
fi

f_step "Step A of D: choose what to install"
f_info "Pick only the chip family on your board (e.g. Spartan-7 FPGAs or Artix-7 FPGAs)."
f_info "Each family adds several GB of download and disk."
if ! bash "/home/user/scripts/select_modules.sh" "$catalog" "$selection"
then
	f_fail "Device selection was cancelled." "Run setup.sh again to start over."
fi
f_ok "Selection saved to install_configs/${config_name}.selected.txt"

f_step "Step B of D: unpacking the installer (a minute or two)..."
if ! "$install_bin_path" --target /home/user/installer --noexec > /dev/null
then
	f_fail "Could not unpack $install_bin_path." \
		"The download may be incomplete. Download it again and run cleanup.sh, then setup.sh."
fi
f_ok "Installer unpacked."

f_step "Step C of D: log into your AMD account"
f_banner "$c_magenta" "➜ AMD LOGIN" \
	"Type the e-mail and password of your AMD account below." \
	"The password does not show while you type. That is normal." \
	"This only lets the installer download Vivado. It is not the license."
while ! /home/user/installer/xsetup -b AuthTokenGen
do
	f_warn "Login failed. Check the e-mail and password and try again."
	sleep 1
done
f_ok "Logged in."

f_step "Step D of D: downloading and installing Vivado $vivado_version"
f_info "This is the long part: often 30-90 minutes, depending on what you picked."
if /home/user/installer/xsetup -c "$selection" -b Install -a "XilinxEULA,3rdPartyEULA"
then
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

    if [ "$vivado_version" = "2026.1" ]
    then
        f_banner "$c_green" "✔ VIVADO $vivado_version IS INSTALLED" \
            "Next:" \
            "1. Double-click \"Start Vivado.command\" in this folder." \
            "2. Vivado 2026.1 needs a free BASIC license before it opens." \
            "   The License Manager pops up by itself. Follow the README's" \
            "   \"Activating the free BASIC license\" section."
    else
        f_banner "$c_green" "✔ VIVADO $vivado_version IS INSTALLED" \
            "Next: double-click \"Start Vivado.command\" in this folder." \
            "Vivado $vivado_version (ML Standard) needs no license file for the free devices."
    fi
else
    f_fail "The Vivado installer stopped with an error (see the lines above)." \
        "Run scripts/cleanup.sh, then scripts/setup.sh to try again."
fi
