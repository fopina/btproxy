#!/bin/sh
# Installs btproxy from the apt or dnf repository that contrib/linux/repo.sh built, as the README tells hosts to,
# with the signatures checked, in a container of the given distribution.
#
#   test/linux_repo.sh <image> <repo.sh output dir> <version>
#
# The repository is read from the directory rather than from Pages. Needs Docker (or DOCKER=podman) and an x86_64
# host.
set -eu

image=$1
site=$(cd "$2" && pwd)
version=$3
docker=${DOCKER:-docker}

case $image in
*debian* | *ubuntu*)
	script='
	set -e
	cp /site/keys/btproxy.gpg /usr/share/keyrings/btproxy.gpg
	sed "s|^URIs: .*|URIs: file:/site/deb|" /site/deb/btproxy.sources > /etc/apt/sources.list.d/btproxy.sources
	apt-get update -q >/dev/null
	DEBIAN_FRONTEND=noninteractive apt-get install -qy btproxy >/dev/null
	dpkg-query -W -f "\${Version}\n" btproxy'
	;;
*fedora*)
	script='
	set -e
	sed -e "s|^baseurl=.*|baseurl=file:///site/rpm/\$basearch|" -e "s|^gpgkey=.*|gpgkey=file:///site/keys/btproxy.asc|" \
		/site/rpm/btproxy.repo > /etc/yum.repos.d/btproxy.repo
	dnf install -qy btproxy >/dev/null
	rpm -K "$(ls /site/rpm/x86_64/*.rpm)" | grep -q "signatures OK"
	rpm -q --qf "%{VERSION}\n" btproxy'
	;;
*)
	echo "unknown distribution: $image" >&2
	exit 2
	;;
esac

got=$($docker run --rm -v "$site:/site:ro" "$image" sh -c "$script" | tail -1)
if [ "$got" != "$version" ]; then
	echo "FAIL ($image): installed version '$got', want $version" >&2
	exit 1
fi
echo "ok ($image)"
