#!/bin/sh
# Install the board-side TV wake helper: copy it into ~/bin and add a once-a-minute cron entry
# for the arduino user (no sudo). Safe to re-run.
set -e
mkdir -p "$HOME/bin"
install -m 755 "$(dirname "$0")/tv-wake.sh" "$HOME/bin/tv-wake.sh"
line="* * * * * $HOME/bin/tv-wake.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v 'tv-wake.sh' ; echo "$line" ) | crontab -
echo "installed:"
crontab -l | grep tv-wake
