#!/bin/zsh

# Generate the Docker image

script_dir=$(dirname -- "$(readlink -nf $0)";)
source "$script_dir/header.sh"
validate_macos

start_docker

# Build the Docker image according to the Dockerfile
f_step "Building the Linux image Vivado runs in (10-20 minutes the first time)..."
if ! docker build --platform linux/amd64 -t x64-linux "$script_dir"
then
	f_fail "Building the Docker image failed (see the lines above)." \
		"A network hiccup is the usual cause: run setup.sh again."
fi

f_ok "Docker image built."