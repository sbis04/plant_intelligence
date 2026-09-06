#!/bin/sh
# Install the MCU watchdog on the board: copy it into ~/bin and add the
# cron entry that runs it once a minute. Safe to re-run.
set -e
mkdir -p "$HOME/bin"
install -m 755 "$(dirname "$0")/mcu-watchdog.sh" "$HOME/bin/mcu-watchdog.sh"
line="* * * * * $HOME/bin/mcu-watchdog.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v 'mcu-watchdog.sh' ; echo "$line" ) | crontab -
echo "installed:"
crontab -l | grep mcu-watchdog
