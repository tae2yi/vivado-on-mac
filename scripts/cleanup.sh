#!/bin/zsh

# Cleans up the folder, removing any Vivado installation

script_dir=$(dirname -- "$(readlink -nf $0)";)
source $script_dir/header.sh
validate_macos

cd $script_dir/..
to_remove=(".cache" ".dbus" ".local" ".vnc" "Xilinx" ".Xilinx"
"Desktop" "installer" ".bash_history" ".lesshst" ".sudo_as_admin_successful"
".Xauthority" ".xsession-errors" ".XIC.lock" ".mozilla" ".java" ".config"
".fontconfig" )

f_banner "$c_yellow" "⚠ REMOVE THE VIVADO INSTALLATION" \
    "This deletes the installed Vivado (the Xilinx folder) and its settings from:" \
    "  $PWD" \
    "Your projects outside those folders, the installer .bin and the scripts stay."
f_ask "Delete it? [y/N]"
read answer
case $answer in
[yY]|[yY][eE][sS]) ;;
*)
    f_ok "Nothing was deleted."
    exit 0
    ;;
esac

# .Xilinx holds the license, which is node-locked to this install's MAC address
# (kept in scripts/mac_address) and so still valid after a reinstall
licenses=(.Xilinx/*.lic(N))
if (( ${#licenses} ))
then
    mkdir -p saved-licenses
    cp $licenses saved-licenses/
    f_ok "Saved your license file(s) to saved-licenses/. Copy them back into .Xilinx after reinstalling."
fi

for file in ${to_remove[@]}
do
    rm -rf $file
done
f_ok "Vivado installation removed. Run scripts/setup.sh to install again."
