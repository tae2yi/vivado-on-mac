# general functions and definitions used by the other scripts

# This script needs to be sourced into other scripts or
# be run explicitly with an interpreter since it has no shebang

script_dir=$(dirname -- "$(readlink -nf $0)";)

# Output helpers, shared by the zsh scripts on macOS and the bash scripts in the
# container. One symbol and colour per kind of line, so the state can be read at
# a glance:  ▶ working on it   ✔ done   ⚠ heads-up   ✖ failed   ➜ your turn
c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_dim=$'\e[2m'
c_red=$'\e[1;31m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_cyan=$'\e[1;36m'; c_magenta=$'\e[1;35m'
c_rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

function f_step { printf '%s\n' "${c_cyan}▶ $1${c_reset}"; }
function f_ok   { printf '%s\n' "${c_green}✔ $1${c_reset}"; }
function f_warn { printf '%s\n' "${c_yellow}⚠ $1${c_reset}"; }
function f_info { printf '%s\n' "${c_dim}  $1${c_reset}"; }
# A line asking the user to do something (answer, drag a file, log in)
function f_ask  { printf '%s\n' "${c_magenta}➜ $1${c_reset}"; }
# Kept for the scripts that print plain status lines
function f_echo { printf '%s\n' "${c_bold}${c_yellow}$1${c_reset}"; }

# A boxed-off message for the things that must not be missed: f_banner <colour> <title> [line...]
function f_banner {
	local color=$1 title=$2 line
	shift 2
	printf '\n%s\n' "${color}${c_rule}${c_reset}"
	printf '%s\n' "${color}┃ ${title}${c_reset}"
	for line in "$@"; do
		printf '%s\n' "${color}┃${c_reset} ${line}"
	done
	printf '%s\n\n' "${color}${c_rule}${c_reset}"
}

# Heading for one stage of a multi-stage script: f_stage <n> <total> <title>
function f_stage {
	printf '\n%s\n' "${c_bold}${c_cyan}━━ [$1/$2] $3 ━━${c_reset}"
}

# Prints a red box with what went wrong and what to do about it, then exits 1.
function f_fail {
	f_banner "$c_red" "✖ FAILED" "$@"
	exit 1
}

# aborts the script if it isn't run on macOS
function validate_macos {
    if [[ $(uname) == *Darwin* ]]
    then
        :
    else
        f_fail "This script runs on macOS, not inside the container."
    fi
}

# aborts the script if it isn't run inside the Docker container
function validate_linux {
    if [[ $(uname) == *Linux* ]]
    then
        :
    else
        f_fail "This script runs inside the container, not on macOS."
    fi
}

function validate_internet {
    if ! ping -q -c1 google.com &>/dev/null
    then
        f_fail "No internet connection." \
            "The installer downloads Vivado from AMD, so connect to the internet and run this again."
    fi
}

function wait_for_user_input {
    f_ask "Press Enter to continue..."
    read
}

function start_docker {
    # check if Docker is installed
    if ! which docker &> /dev/null
    then
        f_fail "Docker Desktop is not installed." \
            "Install the \"Apple Chip\" build from https://www.docker.com/products/docker-desktop/" \
            "or run: brew install --cask docker   — then run this again."
    fi

    # Launch Docker daemon
    f_step "Starting Docker Desktop (this can take a minute the first time)..."
    sleep 2
    # Wait for Docker to start
    while ! docker ps &> /dev/null
    do
        open -a Docker
        sleep 5
    done
    sleep 2
    f_ok "Docker is running."
}

function stop_docker {
    curl -s -X POST -H 'Content-Type: application/json' -d '{ "openContainerView": true }' -kiv --unix-socket "$HOME/Library/Containers/com.docker.docker/Data/backend.sock" http://localhost/engine/stop &> /dev/null
    osascript -e 'quit app "Docker Desktop"'
    sleep 2
}

# The actual resolution is stored in the file vnc_resolution
vnc_default_resolution="1920x1080"

current_user=$(whoami)
