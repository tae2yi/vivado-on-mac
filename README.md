# vivado-on-silicon-mac-2026

This is a fork/derivative of [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac), updated and fixed to install **Vivado 2026.1** on Apple Silicon Macs. It runs Vivado inside a Rosetta-accelerated x86_64 Docker container, with the GUI exposed over VNC, exactly like the original project.

It is in no way associated with Xilinx, AMD, or the original author. Vivado and Xilinx are trademarks of Xilinx, Inc. / AMD.

## What's different from the original project

The original project supports Vivado 2021.1–2024.1. Getting 2026.1 working required several fixes beyond just bumping a version string:

- **Installer flow restored for the real web installer.** The original repo's `setup.sh`/`install_vivado.sh` had the installer-extraction and AMD-account login (`AuthTokenGen`) steps commented out, tuned for a pre-extracted full offline installer. This fork restores that flow, since the actual 2026.1 "Web Installer" is a single self-extracting `.bin` (Makeself archive) that needs to be extracted and requires logging into your AMD account to download packages.
- **New device/module catalog.** Vivado 2026.1's installer uses a different `Edition` name (`Vivado Design Suite` instead of `Vivado ML Standard`) and a much larger `Modules=` catalog (individual device part numbers plus renamed device families, e.g. `Spartan-7` → `Spartan-7 FPGAs`). See `scripts/install_configs/202610.txt`.
- **`eval` breaks on paths containing spaces.** Several scripts used `eval "$script_dir/foo.sh"`, which re-parses the string and word-splits on spaces. If your repo folder path has a space in it (e.g. `~/Library/Application Support/...`), this fails with a confusing "no such file or directory" error. Fixed in `setup.sh` and `start_container.sh`. **Simplest fix on your end: keep the repo path free of spaces** (e.g. `~/Documents/...`), which also avoids relying on this fix entirely.
- **Ubuntu 22.04's `firefox` apt package is a snap stub.** It doesn't work inside Docker (snapd isn't available) and just prints "install with snap install firefox". The Vivado License Manager needs a real browser to complete online license activation. The Dockerfile now installs real Firefox from Mozilla's own apt repository instead.
- **`LD_PRELOAD` doesn't survive `sudo`.** The container needs `LD_PRELOAD` set (several libs) or Vivado crashes with `realloc(): invalid pointer`. The original approach only exported it inside `de_start.sh`'s own process tree, so it worked for the auto-launched Vivado but not for Vivado launched later from a terminal or a `.desktop` icon within the same session. Fixed by setting `LD_PRELOAD` directly in the `.desktop` launcher files' `Exec=` line instead of relying on inherited environment. (A global `/etc/ld.so.preload` was tried and reverted — it affects every process in the container, not just Vivado, and destabilized the desktop's own auto-launch.)
- **`de_start.sh`'s auto-launch path assumed the old install layout.** 2024.1 installed to `Xilinx/Vivado/<version>/`; 2026.1 installs to `Xilinx/<version>/Vivado/` (a "unified" layout shared with Vitis and common `data`/`tps` folders). The glob in `de_start.sh` is updated accordingly.
- **Installer's `installLibs.sh` needs extra packages Ubuntu 22.04 doesn't ship by default**, and license utilities (`lmutil`) need an LSB-compatible dynamic loader that doesn't exist on Ubuntu. Both are baked into the Dockerfile now (see the two extra `RUN apt-get install` / `ln -sf .../ld-lsb-x86-64.so.3` blocks).
- **Container's virtual MAC address is pinned** (`--mac-address` on `docker run`) so the Vivado license Host ID (which is derived from the MAC) stays identical across container restarts — since `--rm` containers otherwise don't guarantee a stable MAC on Docker's default bridge network.

This fork intentionally does **not** include any course-specific example projects, VS Code / Dev Container setup, or Verilog tooling — it's just the Vivado installation environment itself.

## Supported version

Tested against **Vivado 2026.1** (`FPGAs_AdaptiveSoCs_Unified_SDI_2026.1_..._Lin64.bin` web installer) with a Spartan-7 device selection. Other versions/devices will very likely need the same kind of catalog-name and module-selection adjustments described below — see "Adapting to a different version or device" below.

## Prerequisites

- Apple Silicon Mac, [Docker Desktop](https://www.docker.com/products/docker-desktop/) ("Apple Chip" build), Rosetta installed (the installer will prompt to install it if missing)
- An AMD account (free to create) — needed both to download the installer packages and to activate the free BASIC license
- The Vivado **Web Installer** file, downloaded yourself from AMD's site — a single `.bin` file (a few hundred MB), *not* the multi-GB full offline installer. Put it inside this repo's folder.

## Installation

1. Clone this repo **to a path with no spaces** (see the `eval` note above — e.g. `~/Documents/...`, not `~/Library/Application Support/...`).
2. Put the Vivado web installer `.bin` file inside the cloned folder.
3. Run:
   ```
   caffeinate -dim zsh ./scripts/setup.sh
   ```
4. When asked to drag and drop the installation binary, drag in the `.bin` file itself.
5. The container will build, then prompt you to log into your AMD account (this is for downloading the selected packages, not license activation).
6. Batch installation proceeds using `scripts/install_configs/202610.txt`. If you selected different devices than Spartan-7/Artix-7/Zynq-7000, or a future Vivado version renames its catalog again, you may hit an error like:
   ```
   ERROR - The value specified for Edition (...) is invalid. Valid edition names are "...".
   ```
   The error message tells you the correct name directly — just edit `install_configs/202610.txt` and rerun.

## Activating the free BASIC license

Vivado 2026.1 requires activating a (free, annually-renewed) BASIC license — this didn't apply to older `WebPACK`-style free licenses. Steps, done inside the VNC session:

1. Launch Vivado once (Desktop icon or Start Menu). If no valid license is found, the "Vivado License Manager" opens.
2. Under **Obtain License → Get My Full or Purchased Certificate-Based License → Connect Now**, this opens a real browser to AMD's licensing site (log in with the same AMD account). It generates a Node-locked BASIC license tied to this machine's **Host ID**.
3. The Host ID is your container's pinned MAC address without colons — check under **View Host Information** in the License Manager, or run `scripts/xvcd/../../Xilinx/<version>/Vivado/bin/unwrapped/lnx64.o/lmutil lmhostid` inside the container. It should match the `--mac-address` value baked into `setup.sh`/`start_container.sh` (`02:42:ac:11:00:99` → Host ID `0242ac110099`).
4. Once the license shows up under **View License Status** with tier `BASIC` and a Host ID match, you're done — it's valid for 12 months and needs manual renewal after that (repeat this process).

If "Connect Now" does nothing, check that a real Firefox is installed (`firefox --version` inside the container) — this fork's Dockerfile fix should already cover this, but if you rebuilt the image without it, see the Dockerfile fixes above.

## Usage

Same as upstream:
```
./scripts/start_container.sh
```
This starts the container, opens Screen Sharing to the VNC session, and runs `xvcd` on the host for USB/JTAG forwarding (FT2232C-based cables only; see upstream README for details on the XVC protocol and its limitations).

## Adapting to a different version or device

- `scripts/setup.sh` and `scripts/install_vivado.sh` hardcode the version string (currently `2026.1` / `202610`) instead of relying on the original hash-based auto-detection in `scripts/hashes.sh` (which is unmaintained past 2024.1). Update both if you use a different version.
- `scripts/install_configs/202610.txt`'s `Modules=` line is a full, ordered list of every catalog entry with `:0`/`:1` flags. To select different devices, find the exact family name from the installer's own error message (see step 6 above) and flip its flag to `:1`. Don't remove or reorder entries.

## Files overview

See upstream's own description of `header.sh`, `setup.sh`, `start_container.sh`, `configure_docker.sh`, `gen_image.sh`, `hashes.sh`, `linux_start.sh`, `de_start.sh`, `cleanup.sh`, `xvcd`, `install_bin`, `vnc_resolution`, `vncpasswd` — unchanged in purpose here. New/changed in this fork: `install_configs/202610.txt` (2026.1 batch config) and the Dockerfile additions listed above.

## License, copyright and trademark information

Same terms as upstream: the repository's contents are licensed under the **Creative Commons Zero v1.0 Universal** license.

Running these scripts means you agree to Xilinx'/AMD's and third-party EULAs (obtainable by extracting the installer yourself) and to [Apple's software license agreement](https://www.apple.com/legal/sla/) for Rosetta 2.

This repository contains the modified source code of [xvcd](https://github.com/tmbinc/xvcd) by Felix Domke, as well as a compiled version statically linked against [libusb](https://libusb.info/) and [libftdi](https://www.intra2net.com/en/developer/libftdi/), in accordance with the [LGPL v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) under which both libraries are licensed.

Vivado and Xilinx are trademarks of Xilinx, Inc. Arm is a registered trademark of Arm Limited. Apple, Mac, macOS and Rosetta are trademarks of Apple Inc. Docker and the Docker logo are trademarks of Docker, Inc. Linux® is the registered trademark of Linus Torvalds.
