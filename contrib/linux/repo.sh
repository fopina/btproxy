#!/bin/sh
# Builds the signed apt and dnf repositories from a release's deb and rpm packages.
#
#   contrib/linux/repo.sh <dir with the packages> <output dir> <armored OpenPGP secret key>
#
# Run on Debian 13 or later with apt-utils, gnupg, createrepo-c and rpm installed. The output is
# <output dir>/deb/ (an apt repository with the suite "stable") and <output dir>/rpm/<basearch>/ with btproxy.repo,
# with only the latest release in each, plus the public key in <output dir>/keys/.
set -eu

packages=$1
out=$2
key=$3

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg -q --batch --import "$key"
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
[ -n "$fpr" ] || { echo "no secret key in $key" >&2; exit 1; }
sign() { gpg -q --batch --yes --local-user "$fpr" "$@"; }

mkdir -p "$out/keys"
gpg --batch --armor --export "$fpr" > "$out/keys/btproxy.asc"
gpg --batch --export "$fpr" > "$out/keys/btproxy.gpg"
base=https://yuzi-co.github.io/btproxy

# apt: one pool, an index per architecture, and a Release file signed both inline and detached.
deb=$out/deb
arches=
mkdir -p "$deb/pool/main"
for package in "$packages"/btproxy-linux-*.deb; do
	[ -e "$package" ] || continue
	arch=$(dpkg-deb -f "$package" Architecture)
	cp "$package" "$deb/pool/main/btproxy_$(dpkg-deb -f "$package" Version)_$arch.deb"
	arches="$arches $arch"
done
[ -n "$arches" ] || { echo "no deb packages in $packages" >&2; exit 1; }
arches=${arches# }
dists=$deb/dists/stable
for arch in $arches; do
	mkdir -p "$dists/main/binary-$arch"
	(cd "$deb" && apt-ftparchive --arch "$arch" packages pool) > "$dists/main/binary-$arch/Packages"
	gzip -9nk "$dists/main/binary-$arch/Packages"
done
apt-ftparchive \
	-o APT::FTPArchive::Release::Origin=btproxy -o APT::FTPArchive::Release::Label=btproxy \
	-o APT::FTPArchive::Release::Suite=stable -o APT::FTPArchive::Release::Codename=stable \
	-o "APT::FTPArchive::Release::Architectures=$arches" -o APT::FTPArchive::Release::Components=main \
	release "$dists" > "$out/Release.tmp"
mv "$out/Release.tmp" "$dists/Release"
sign --clearsign -o "$dists/InRelease" "$dists/Release"
sign --detach-sign --armor -o "$dists/Release.gpg" "$dists/Release"
cat > "$deb/btproxy.sources" <<SOURCES
Types: deb
URIs: $base/deb
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/btproxy.gpg
SOURCES

# dnf: a repository per architecture, with signed packages and signed metadata.
rpmdir=$out/rpm
found=
for package in "$packages"/btproxy-linux-*.rpm; do
	[ -e "$package" ] || continue
	found=1
	case $(rpm -qp --qf '%{ARCH}' "$package") in
	x86_64) basearch=x86_64 ;;
	aarch64) basearch=aarch64 ;;
	armv7hl) basearch=armhfp ;;
	*) echo "unknown architecture: $package" >&2; exit 1 ;;
	esac
	mkdir -p "$rpmdir/$basearch"
	cp "$package" "$rpmdir/$basearch/"
	rpmsign --define "_gpg_name $fpr" --define "_gpg_path $GNUPGHOME" --addsign \
		"$rpmdir/$basearch/${package##*/}" >/dev/null
done
[ -n "$found" ] || { echo "no rpm packages in $packages" >&2; exit 1; }
for dir in "$rpmdir"/*/; do
	# gzip, which older dnf and yum read too.
	createrepo_c -q --general-compress-type=gz "$dir"
	sign --detach-sign --armor -o "$dir/repodata/repomd.xml.asc" "$dir/repodata/repomd.xml"
done
cat > "$rpmdir/btproxy.repo" <<REPO
[btproxy]
name=btproxy
baseurl=$base/rpm/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$base/keys/btproxy.asc
REPO
