# vivado-on-silicon-mac-2026

Installs **Vivado 2026.1** on Apple Silicon Macs. It runs Vivado inside a Rosetta-accelerated x86_64 Docker container, with the GUI exposed over VNC.

It is in no way associated with Xilinx or AMD. Vivado and Xilinx are trademarks of Xilinx, Inc. / AMD.

## Table of contents

- [Quick start](#quick-start)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Activating the free BASIC license](#activating-the-free-basic-license)
- [Everyday usage](#everyday-usage)
- [Troubleshooting](#troubleshooting)
- [Adapting to a different Vivado version or device](#adapting-to-a-different-vivado-version-or-device)
- [What changed from the reference project](#what-changed-from-the-reference-project)
- [Files overview](#files-overview)
- [License, copyright and trademark information](#license-copyright-and-trademark-information)
- [References](#references)

## Quick start

For anyone who just wants the environment running with minimal reading. Every step is explained in more detail further down — come back here if something goes wrong.

1. **Install Docker Desktop** ("Apple Chip" build) and let it install Rosetta if it asks.
2. **Create a free AMD account** at amd.com, if you don't have one.
3. **Download the Vivado 2026.1 Web Installer** from AMD's site — look for a file named like `FPGAs_AdaptiveSoCs_Unified_SDI_2026.1_..._Lin64.bin`, roughly a few hundred MB. Don't download the multi-gigabyte full offline installer.
4. **Clone this repo somewhere with no spaces in the path**, e.g. `~/Documents/vivado-on-silicon-mac-2026` (not `~/Library/Application Support/...`).
5. Move the downloaded `.bin` file into the cloned folder.
6. Run:
   ```
   caffeinate -dim zsh ./scripts/setup.sh
   ```
   and follow the yellow prompts — drag in the `.bin` file when asked, then log into your AMD account when the container asks for it.
7. **Activate the free BASIC license** — Vivado 2026.1 refuses to open at all without this, so don't skip it:
   1. Launch Vivado (Desktop icon or Start Menu, inside the VNC session). Since no license exists yet, the **Vivado License Manager** pops up with an error instead of the main window — that's expected.
   2. In the License Manager, go to **Obtain License → Get My Full or Purchased Certificate-Based License**, then click **Connect Now**. This opens a real browser to AMD's licensing page — log in with the same AMD account from step 2.
   3. AMD's site generates a free, node-locked BASIC license for this specific machine, identified by its **Host ID**. You don't need to do anything with the Host ID yourself — this repo already pins it (`--mac-address` in `setup.sh`/`start_container.sh`) so it stays the same every time you restart the container.
   4. Back in the License Manager, click **View License Status** and confirm it shows tier `BASIC` with the Host ID matching. That's it — it's valid for 12 months, after which you repeat this same process to renew.
   5. Close the License Manager and launch Vivado again — it should now open normally.

   More detail and what to do if `Connect Now` doesn't respond: [Activating the free BASIC license](#activating-the-free-basic-license).
8. From then on, just run `./scripts/start_container.sh` to open Vivado.

If anything above fails, jump to [Troubleshooting](#troubleshooting) or the detailed section for that step.

## Prerequisites

- An Apple Silicon Mac
- [Docker Desktop](https://www.docker.com/products/docker-desktop/), the "Apple Chip" build
- Rosetta (the installer prompts you to install it if it's missing)
- A free AMD account — needed both to download installer packages and to activate the free BASIC license
- The Vivado **Web Installer** file, downloaded yourself from AMD's site — a single `.bin` file, *not* the multi-GB full offline installer. Put it inside this repo's folder once downloaded.

## Installation

1. Clone this repo **to a path with no spaces** — see [Troubleshooting](#troubleshooting) for why this matters.
2. Put the Vivado web installer `.bin` file inside the cloned folder.
3. Run:
   ```
   caffeinate -dim zsh ./scripts/setup.sh
   ```
4. When asked to drag and drop the installation binary, drag in the `.bin` file itself.
5. The container builds, then prompts you to log into your AMD account. This step downloads the selected packages — it's separate from license activation, which happens later.
6. Batch installation proceeds using `scripts/install_configs/202610.txt` (preselected for Spartan-7, Artix-7, Zynq-7000, and DocNav). If you want different devices, or a future Vivado version renames its catalog, you may see:
   ```
   ERROR - The value specified for Edition (...) is invalid. Valid edition names are "...".
   ```
   The error message tells you the correct name directly — edit `install_configs/202610.txt` and rerun `setup.sh`.

## Activating the free BASIC license

Vivado 2026.1 requires activating a free, node-locked, annually-renewed **BASIC** license — older `WebPACK`-style "no license file needed at all" licensing doesn't apply here. Do this inside the VNC session, after installation finishes:

1. Launch Vivado (Desktop icon or Start Menu). If no valid license is found, the **Vivado License Manager** opens automatically.
2. Go to **Obtain License → Get My Full or Purchased Certificate-Based License → Connect Now**. This opens a real browser to AMD's licensing site — log in with the same AMD account. It generates a Node-locked BASIC license tied to this machine's **Host ID**.
3. The Host ID is your container's pinned MAC address without colons. You can check it under **View Host Information** in the License Manager, or by running (inside the container):
   ```
   .../Xilinx/<version>/Vivado/bin/unwrapped/lnx64.o/lmutil lmhostid
   ```
   It should match the `--mac-address` baked into `setup.sh`/`start_container.sh` (`02:42:ac:11:00:99` → Host ID `0242ac110099`).
4. Once **View License Status** shows tier `BASIC` with a Host ID match, you're done. It's valid for 12 months; repeat this process to renew.

**If "Connect Now" does nothing:** check that a real Firefox is installed (`firefox --version` inside the container). This repo's Dockerfile already fixes a common Ubuntu/Docker Firefox problem (see [Troubleshooting](#troubleshooting)) — this only matters if you rebuilt the image some other way.

## Everyday usage

Once installed, day to day you only need:
```
./scripts/start_container.sh
```
This starts the container, opens Screen Sharing to the VNC session, and runs `xvcd` on the host for USB/JTAG forwarding (FT2232C-based cables only — see the [xvcd README](scripts/xvcd/README) for details and limitations of the XVC protocol).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no such file or directory: /Users/you/Library/Application` (or similar truncated path) | Your repo path has a space in it (e.g. `~/Library/Application Support/...`). Some scripts use `eval` internally, which re-splits on spaces. Simplest fix: clone the repo somewhere without spaces, like `~/Documents/...`. |
| Vivado License Manager: "no valid license was not found" | Expected on first launch — follow [Activating the free BASIC license](#activating-the-free-basic-license). |
| `Connect Now` in the License Manager does nothing | The container's Firefox isn't working. Ubuntu 22.04's `firefox` apt package is a snap stub that can't run in Docker; this repo's Dockerfile installs a real Firefox from Mozilla's own apt repo instead — make sure you're using the current `scripts/Dockerfile` and rebuilt the image (`./scripts/gen_image.sh`). |
| Vivado crashes immediately with `realloc(): invalid pointer` | Missing `LD_PRELOAD`. This normally only happens if you launch `bin/vivado` in some way this repo doesn't already patch (see [What changed](#what-changed-from-the-reference-project)) — `install_vivado.sh` should already have fixed every generated launcher automatically. |
| `ERROR - The value specified for Edition (...) is invalid` during install | The catalog names in `install_configs/202610.txt` don't match what the installer expects. The error itself states the correct name — edit the file and rerun. |
| Batch install complains about an invalid `Modules=` entry name | Same as above, but for a device/module name instead of the edition. Find the correct name in the installer's error and fix that specific entry (don't remove or reorder others). |

## Adapting to a different Vivado version or device

- `scripts/setup.sh` and `scripts/install_vivado.sh` hardcode the version string (currently `2026.1` / `202610`) rather than using the original hash-based auto-detection in `scripts/hashes.sh` (unmaintained past 2024.1). Update both if you use a different version.
- `scripts/install_configs/202610.txt`'s `Modules=` line is a full, ordered list of every catalog entry with `:0`/`:1` flags. To select different devices, find the exact family name from the installer's own error message (see [Installation](#installation) step 6) and flip its flag to `:1`. Don't remove or reorder entries.

## What changed from the reference project

The project this is based on supports Vivado 2021.1–2024.1. Getting 2026.1 working required more than bumping a version string:

- **Installer flow restored for the real web installer.** The reference scripts had the installer-extraction and AMD-account login (`AuthTokenGen`) steps commented out, tuned for a pre-extracted full offline installer. This repo restores that flow, since 2026.1's "Web Installer" is a single self-extracting `.bin` (Makeself archive) that needs to be extracted and requires an AMD account login to download packages.
- **New device/module catalog.** Vivado 2026.1 uses a different `Edition` name (`Vivado Design Suite` instead of `Vivado ML Standard`) and a much larger `Modules=` catalog (individual device part numbers plus renamed device families, e.g. `Spartan-7` → `Spartan-7 FPGAs`). See `scripts/install_configs/202610.txt`.
- **`eval` breaks on paths containing spaces.** Several scripts used `eval "$script_dir/foo.sh"`, which re-parses the string and word-splits on spaces — a problem if your folder path has one (e.g. `~/Library/Application Support/...`). Fixed in `setup.sh` and `start_container.sh`.
- **Ubuntu 22.04's `firefox` apt package is a snap stub.** It doesn't work inside Docker (no snapd) and just prints "install with snap install firefox". The Vivado License Manager needs a real browser for online license activation. The Dockerfile now installs real Firefox from Mozilla's own apt repository instead.
- **`LD_PRELOAD` doesn't survive `sudo`.** The container needs `LD_PRELOAD` set (several libs) or Vivado crashes with `realloc(): invalid pointer`. The reference approach only exported it inside `de_start.sh`'s own process tree, so it worked for the auto-launched Vivado but not for Vivado launched later from a terminal or a `.desktop` icon in the same session. Fixed by having `install_vivado.sh` automatically patch every generated `.desktop` launcher that runs `bin/vivado`, baking `LD_PRELOAD` directly into its `Exec=` line right after installation finishes. (A global `/etc/ld.so.preload` was tried and reverted — it affects every process in the container, not just Vivado, and destabilized the desktop's own auto-launch.)
- **`de_start.sh`'s auto-launch path assumed the old install layout.** 2024.1 installed to `Xilinx/Vivado/<version>/`; 2026.1 installs to `Xilinx/<version>/Vivado/` (a "unified" layout shared with Vitis and common `data`/`tps` folders). The glob in `de_start.sh` is updated accordingly.
- **Installer's `installLibs.sh` needs extra packages Ubuntu 22.04 doesn't ship by default**, and license utilities (`lmutil`) need an LSB-compatible dynamic loader that doesn't exist on Ubuntu. Both are baked into the Dockerfile now.
- **Container's virtual MAC address is pinned** (`--mac-address` on `docker run`) so the Vivado license Host ID (derived from the MAC) stays identical across container restarts — `--rm` containers otherwise don't guarantee a stable MAC on Docker's default bridge network.

This repo intentionally does **not** include any course-specific example projects, VS Code / Dev Container setup, or Verilog tooling — it's just the Vivado installation environment itself.

## Files overview

Unchanged in purpose from the reference project: `header.sh`, `setup.sh`, `start_container.sh`, `configure_docker.sh`, `gen_image.sh`, `hashes.sh`, `linux_start.sh`, `de_start.sh`, `cleanup.sh`, `xvcd/`, `install_bin`, `vnc_resolution`, `vncpasswd`.

New/changed here: `install_configs/202610.txt` (2026.1 batch config) and the Dockerfile additions described in [What changed](#what-changed-from-the-reference-project).

## License, copyright and trademark information

The repository's contents are licensed under the **Creative Commons Zero v1.0 Universal** license.

Running these scripts means you agree to Xilinx'/AMD's and third-party EULAs (obtainable by extracting the installer yourself) and to [Apple's software license agreement](https://www.apple.com/legal/sla/) for Rosetta 2.

This repository contains the modified source code of [xvcd](https://github.com/tmbinc/xvcd) by Felix Domke, as well as a compiled version statically linked against [libusb](https://libusb.info/) and [libftdi](https://www.intra2net.com/en/developer/libftdi/), in accordance with the [LGPL v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html) under which both libraries are licensed.

Vivado and Xilinx are trademarks of Xilinx, Inc. Arm is a registered trademark of Arm Limited. Apple, Mac, macOS and Rosetta are trademarks of Apple Inc. Docker and the Docker logo are trademarks of Docker, Inc. Linux® is the registered trademark of Linus Torvalds.

## References

This project's overall approach (Docker + Rosetta + VNC to run Vivado on Apple Silicon) and its scripts are based on [ichi4096/vivado-on-silicon-mac](https://github.com/ichi4096/vivado-on-silicon-mac). See [What changed from the reference project](#what-changed-from-the-reference-project) for what was updated to support Vivado 2026.1.
