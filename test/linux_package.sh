#!/bin/sh
# Installs, upgrades and removes the deb or rpm package in a container of the given distribution, under systemd.
#
#   test/linux_package.sh <image> <dir with the newer btproxy-linux-amd64.{deb,rpm}> <dir with the older one>
#
# The image is a Debian, Ubuntu or Fedora one, such as debian:trixie or fedora:44. The radio is the fake backend,
# chosen through a drop-in. Needs Docker (or DOCKER=podman) and an x86_64 host.
set -eu

image=$1
new=$(cd "$2" && pwd)
old=$(cd "$3" && pwd)
docker=${DOCKER:-docker}
name=btproxy-linux-test-$$

case $image in
*debian* | *ubuntu*)
	fmt=deb
	prep='apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -qy systemd dbus >/dev/null'
	install='DEBIAN_FRONTEND=noninteractive apt-get install -qy'
	remove='apt-get remove -qy btproxy'
	;;
*fedora*)
	fmt=rpm
	prep='dnf install -qy systemd dbus-broker procps-ng >/dev/null'
	install='dnf install -qy'
	remove='dnf remove -qy btproxy'
	;;
*)
	echo "unknown distribution: $image" >&2
	exit 2
	;;
esac

fail() {
	echo "FAIL ($image): $*" >&2
	run 'journalctl -u btproxy --no-pager | tail -20' >&2 || true
	exit 1
}
run() { $docker exec "$name" sh -c "$1"; }
cleanup() {
	$docker rm -f "$name" >/dev/null 2>&1 || true
	$docker rmi -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# An image of the distribution with systemd, booted as PID 1.
$docker run --name "$name" "$image" sh -c "$prep"
$docker commit "$name" "$name" >/dev/null
$docker rm "$name" >/dev/null
if [ "$docker" = podman ]; then
	boot="--systemd=always --privileged"
else
	boot="--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --tmpfs /tmp"
fi
# shellcheck disable=SC2086 # $boot is a list of options
$docker run -d --name "$name" $boot -v "$new:/pkg/new:ro" -v "$old:/pkg/old:ro" "$name" /usr/lib/systemd/systemd >/dev/null
for _ in $(seq 60); do
	state=$(run 'systemctl is-system-running' 2>/dev/null) || true
	case $state in running | degraded) break ;; esac
	sleep 1
done
case $state in running | degraded) ;; *) fail "systemd did not boot: $state" ;; esac

# wait_started <version>: the service runs that version, on the fake radio.
wait_started() {
	for _ in $(seq 30); do
		if run "journalctl -u btproxy --no-pager | grep 'btproxy started' | tail -1 | grep -q 'version=$1'"; then
			run 'systemctl is-active -q btproxy' && return 0
		fi
		sleep 1
	done
	fail "version $1 not running"
}

# First install: the service is enabled and started. No adapter here, so it fails until a drop-in picks the fake
# radio, and restarts meanwhile.
run "$install /pkg/old/btproxy-linux-amd64.$fmt" >/dev/null || fail "install"
run 'test -x /usr/bin/btproxy' || fail "no binary"
run 'systemctl is-enabled -q btproxy' || fail "not enabled"
run 'systemd-analyze verify btproxy.service' || fail "unit does not verify"
[ "$(run 'stat -c %a /etc/btproxy')" = 700 ] || fail "settings directory not 0700"
[ "$(run 'stat -c %a /etc/btproxy/config.json')" = 600 ] || fail "settings file not 0600"
run 'printf "%s\n" "{\"area\": \"Kept\"}" > /etc/btproxy/config.json'
# The fake radio through a drop-in, as systemctl edit writes, which the upgrade must keep too.
run 'mkdir -p /etc/systemd/system/btproxy.service.d && printf "%s\n" "[Service]" "ExecStart=" "ExecStart=/usr/bin/btproxy -config /etc/btproxy/config.json -backend fake -mdns=false -mac 02:00:00:00:00:01" > /etc/systemd/system/btproxy.service.d/override.conf && systemctl daemon-reload'
run 'systemctl restart btproxy'
wait_started 0.0.1

# Upgrade: the edited settings stay and the new version starts.
run "$install /pkg/new/btproxy-linux-amd64.$fmt" >/dev/null || fail "upgrade"
run 'grep -q Kept /etc/btproxy/config.json' || fail "settings lost on upgrade"
wait_started 0.0.2
run 'systemctl is-enabled -q btproxy' || fail "not enabled after the upgrade"

# Removal stops and disables the service; the settings stay.
run "$remove" >/dev/null || fail "remove"
if run 'test -e /usr/bin/btproxy'; then fail "binary left"; fi
if run 'systemctl is-active -q btproxy'; then fail "still running"; fi
run 'grep -qs Kept /etc/btproxy/config.json || grep -qs Kept /etc/btproxy/config.json.rpmsave' || fail "settings removed"
if [ "$fmt" = deb ]; then
	run 'apt-get purge -qy btproxy' >/dev/null || fail "purge"
	if run 'test -e /etc/btproxy'; then fail "purge left /etc/btproxy"; fi
fi
echo "ok ($image)"
