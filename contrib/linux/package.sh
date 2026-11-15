#!/bin/sh
# Builds the deb and rpm packages of a release for each architecture given.
#
#   contrib/linux/package.sh <version> <output dir> <arch>=<binary>...
#
# arch is amd64, arm64 or armv7, as in the release's file names. Needs Go, which runs nfpm. Run from the repository
# root.
set -eu

if [ $# -lt 3 ]; then
	echo "usage: $0 <version> <output dir> <arch>=<binary>..." >&2
	exit 2
fi
version=$1
out=$2
shift 2
mkdir -p "$out"
config=$(mktemp)
trap 'rm -f "$config"' EXIT
for pair; do
	arch=${pair%%=*}
	case $arch in
	armv7) nfpm_arch=arm7 ;;
	*) nfpm_arch=$arch ;;
	esac
	# nfpm expands the environment in some fields only, and not in a file's source.
	sed "s|@BINARY@|${pair#*=}|" contrib/linux/nfpm.yaml >"$config"
	for format in deb rpm; do
		VERSION=$version ARCH=$nfpm_arch \
			go run github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.48.0 package \
			--config "$config" --packager "$format" --target "$out/btproxy-linux-$arch.$format"
	done
done
