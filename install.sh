#!/bin/sh
# Install Atoll: download the latest release into /Applications.
# curl downloads don't get the macOS quarantine flag, so Gatekeeper
# won't block the (ad-hoc signed) app the way a browser download would.
#
# Where new sessions start can be set here, in order of precedence:
#   ATOLL_DIR=~/code sh install.sh    env var (also good for scripted installs)
#   sh install.sh ~/code             first argument
#   otherwise you're prompted, defaulting to the first checkout root found
# ATOLL_DIR=skip leaves the pref alone (the app picks a directory itself).
set -e
ZIP_URL="https://github.com/pjoachims/atoll/releases/latest/download/Atoll.zip"

# first existing of the usual checkout roots; mirrors Config.defaultLaunchDir
guess_dir() {
  for d in "$HOME/Documents/git" "$HOME/Documents/repos" "$HOME/Developer" \
           "$HOME/repos" "$HOME/dev" "$HOME/src" "$HOME/code" "$HOME/projects"; do
    if [ -d "$d" ]; then echo "$d"; return; fi
  done
  echo "$HOME"
}

DIR="${ATOLL_DIR:-$1}"
DEFAULT_DIR=$(guess_dir)
# `curl … | sh` leaves the script on stdin, so ask on the terminal directly
if [ -z "$DIR" ] && [ -r /dev/tty ]; then
  printf "New sessions start in [%s]: " "$DEFAULT_DIR" > /dev/tty
  read -r DIR < /dev/tty || DIR=""
fi
DIR="${DIR:-$DEFAULT_DIR}"
case "$DIR" in
  "~") DIR="$HOME" ;;
  "~/"*) DIR="$HOME/${DIR#\~/}" ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading latest Atoll..."
curl -fsSL -o "$TMP/Atoll.zip" "$ZIP_URL"
ditto -xk "$TMP/Atoll.zip" "$TMP"

pkill -x Atoll 2>/dev/null || true
rm -rf "/Applications/Atoll.app"
# Atoll used to be Claude Island; retire the old install
pkill -x ClaudeIsland 2>/dev/null || true
rm -rf "/Applications/Claude Island.app"
ditto "$TMP/Atoll.app" "/Applications/Atoll.app"
xattr -dr com.apple.quarantine "/Applications/Atoll.app" 2>/dev/null || true

# written while the app is stopped, so it can't be clobbered on quit
if [ "$DIR" = "skip" ]; then
  :
elif [ -d "$DIR" ]; then
  defaults write dev.pj.atoll launchDir -string "$DIR"
  echo "New sessions start in: $DIR"
else
  echo "warning: $DIR is not a directory; Atoll will pick one itself" >&2
fi

echo "Installed: /Applications/Atoll.app"
open "/Applications/Atoll.app"
