#!/bin/sh
# Stops the service when the package goes, not on an upgrade. Arguments: deb "remove", rpm 0.
set -e
[ -d /run/systemd/system ] || exit 0
case "$1" in
0 | remove) systemctl disable --now btproxy.service || true ;;
esac
