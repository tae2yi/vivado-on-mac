# Container for running Vivado on M1/M2 macs
# though it should work equally on Intel macs
FROM --platform=linux/amd64 ubuntu:22.04
RUN apt-get update && apt-get upgrade -y

# Fix the error of build failing due to not having the frontend installed
# This enviroment auto fallbacks to noninteractive mode, with the declaration following this guidance:
# https://bobcares.com/blog/debian_frontendnoninteractive-docker/
# https://github.com/moby/moby/issues/4032#issuecomment-34597177
ARG DEBIAN_FRONTEND=noninteractive

# Check and install ca-certificates earlier if Rosetta gets broken
RUN apt -y install ca-certificates

# install gui
RUN apt-get install -y --no-install-recommends \
    dbus dbus-x11 x11-utils xorg alsa-utils mesa-utils net-tools \
    libgl1-mesa-dri gtk2-engines lxappearance fonts-droid-fallback sudo \
    ubuntu-gnome-default-settings curl gnupg lxde arc-theme \
    gtk2-engines-murrine gtk2-engines-pixbuf gnome-themes-standard nano xterm

# Ubuntu 22.04's firefox apt package is a snap stub that doesn't work in Docker;
# install the real Mozilla-provided .deb package instead
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list && \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla && \
    apt-get update && apt-get install -y --no-install-recommends firefox

# install dependencies for Vivado
RUN apt-get install -y --no-install-recommends \
    python3-pip python3-dev build-essential git gcc-multilib g++ \
    ocl-icd-opencl-dev libjpeg62-dev libc6-dev-i386 graphviz make \
    unzip libtinfo5 xvfb libncursesw5 locales libswt-gtk-4-jni

# additional dependencies required by Vivado 2026.1's installLibs.sh
RUN apt-get install -y --no-install-recommends \
    zip libtool libyaml-dev libncurses5 libncurses5-dev libnss3-dev \
    libgdk-pixbuf2.0-dev libgtk-3-dev libxss-dev libasound2 openssl \
    fdisk libsecret-1-dev

# Xilinx license utilities (lmutil) expect the LSB-compliant dynamic loader,
# which does not exist by default on Ubuntu
RUN mkdir -p /usr/lib64 && \
    ln -sf /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /usr/lib64/ld-lsb-x86-64.so.3

# install vnc server (with recommended installs)
RUN apt-get install -y \
    tigervnc-standalone-server tigervnc-xorg-extension

# create user "user" with password "password"
RUN useradd --create-home --shell /bin/bash --user-group --groups adm,sudo user
RUN sh -c 'echo "user:password" | chpasswd'
# RUN cp -r /root/{.config,.gtkrc-2.0,.asoundrc} /home/user
RUN chown -R user:user /home/user
# setup LXDE
RUN mkdir -p /home/user/.config/pcmanfm/LXDE/
RUN ln -sf /usr/local/share/doro-lxde-wallpapers/desktop-items-0.conf \
    /home/user/.config/pcmanfm/LXDE/
RUN mv /usr/bin/lxpolkit /usr/bin/lxpolkit.bak
#RUN echo "" >> /etc/xdg/lxsession/LXDE/autostart
#RUN echo "@lxterminal -e /home/user/scripts/de_start.sh" >> /etc/xdg/lxsession/LXDE/autostart
# setup TigerVNC
RUN sed -i 's/-iconic/-nowin/g' /etc/X11/Xtigervnc-session
RUN mkdir /home/user/.vnc
RUN echo "password" | vncpasswd -f > /vncpasswd
RUN chown user /vncpasswd
RUN chmod 600 /vncpasswd

# Set the locale, because Vivado crashes otherwise
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Without this, Vivado will crash when synthesizing
ENV LD_PRELOAD="/lib/x86_64-linux-gnu/libudev.so.1 /lib/x86_64-linux-gnu/libselinux.so.1 /lib/x86_64-linux-gnu/libz.so.1 /lib/x86_64-linux-gnu/libgdk-x11-2.0.so.0"

# JTAG cable forwarding: usbutils provides lsusb. No fxload: hw_server loads
# a Platform Cable's firmware itself. The usbip client can't come from apt -
# Ubuntu only ships it as linux-tools-<version>-generic, tied to a kernel
# version this image's LinuxKit kernel doesn't have a package for - so it's
# built from the kernel source tree instead, pinned to the release matching
# Docker Desktop's 6.12 kernel so the build doesn't change under us. Built
# into the image (not the bind-mounted folder) since the container runs with
# --rm and would otherwise lose it on exit.
RUN apt-get install -y --no-install-recommends \
    usbutils autoconf automake libtool libudev-dev && \
    git clone --depth 1 --branch v6.12 --filter=blob:none --sparse https://github.com/torvalds/linux.git /tmp/linux && \
    cd /tmp/linux && git sparse-checkout set tools/usb/usbip && \
    cd tools/usb/usbip && ./autogen.sh && ./configure && make && make install && \
    ldconfig && \
    rm -rf /tmp/linux
