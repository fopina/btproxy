#!/bin/sh
# Starts the service on a new install and restarts it on an upgrade. Arguments: deb "configure" and the old version,
# empty on a new install; rpm the number of versions installed, 1 on a new install.
set -e
[ -d /run/systemd/system ] || exit 0 # no systemd running, as in a container
systemctl daemon-reload
case "$1" in
1 | configure)
	if [ "$1" = 1 ] || [ -z "$2" ]; then
		systemctl enable --now btproxy.service || true
	else
		systemctl try-restart btproxy.service || true
	fi
	;;
*) systemctl try-restart btproxy.service || true ;;
esac
