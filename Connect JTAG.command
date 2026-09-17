#!/bin/zsh
# Double-click this file in Finder to attach the JTAG cable over USB/IP,
# equivalent to running ./scripts/jtag_connect.sh by hand.

cd -- "$(dirname -- "$0")"
./scripts/jtag_connect.sh
