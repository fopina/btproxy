#!/bin/sh
# Forgets the unit once it is gone, and on a deb purge removes the settings and the keys of bonded devices.
set -e
if [ "$1" = purge ]; then
	rm -rf /etc/btproxy
fi
[ -d /run/systemd/system ] || exit 0
systemctl daemon-reload
