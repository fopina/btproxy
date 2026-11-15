#!/bin/sh
# Generates the signing key of the apt and dnf repositories, once, on the maintainer's machine. Needs Docker (or
# DOCKER=podman).
#
#   contrib/linux/repo-keygen.sh [--no-upload] <empty dir for the private key>
#
# The private key stays in that directory as repo.sec: copy it somewhere offline, because a lost or leaked key means
# every host has to fetch a new one by hand. The public key goes in contrib/linux/keys, to commit.
#
# Unless told --no-upload, it also stores the private key as a secret of the openwrt-feed environment, which builds
# the whole Pages site and only v* tags can use; that needs gh signed in as an admin. Neither this script nor gh
# prints the key.
set -eu

upload=1
if [ "$1" = --no-upload ]; then
	upload=
	shift
fi
dir=$1
docker=${DOCKER:-docker}
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$dir"
if [ -n "$(ls -A "$dir")" ]; then
	echo "$dir is not empty, and this would replace its key" >&2
	exit 1
fi
if [ -n "$upload" ] && [ -e "$here/keys/btproxy.asc" ]; then
	echo "$here/keys already has a public key: the repositories have their key" >&2
	exit 1
fi
mount=$(cd "$dir" && pwd)

# RSA rather than Ed25519, which the rpm of RHEL 8 and 9 cannot check. No passphrase, since CI signs with it, and no
# expiry, since hosts would stop upgrading when it lapsed.
$docker run --rm -v "$mount:/keys" debian:trixie sh -c '
	set -e
	apt-get update -qq && apt-get install -qqy --no-install-recommends gnupg >/dev/null
	export GNUPGHOME=$(mktemp -d)
	gpg -q --batch --passphrase "" --quick-generate-key "btproxy packages <7278850+yuzi-co@users.noreply.github.com>" rsa4096 sign never
	umask 077
	gpg --batch --armor --export-secret-keys > /keys/repo.sec
	gpg --batch --armor --export > /keys/btproxy.asc
	chown -R "$(stat -c %u:%g /keys)" /keys'
chmod 600 "$dir/repo.sec"
echo "The key is in $dir. Copy it somewhere offline."

[ -n "$upload" ] || exit 0

mkdir -p "$here/keys"
cp "$dir/btproxy.asc" "$here/keys/btproxy.asc"
gh secret set LINUX_REPO_GPG_KEY --env openwrt-feed < "$dir/repo.sec"
echo "Secret stored. Commit contrib/linux/keys."
