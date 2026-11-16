#!/usr/bin/env bash
# LibreLane 3.0.14 has EQY/SBY but no make. Build a project-local static make
# for use inside that container, without changing the host or base image.
set -euo pipefail
cd "$(dirname "$0")/../.."
base="$PWD/build/eda-tools"
mkdir -p "$base/bin"
# A static BusyBox provides awk/sed, also absent from this EDA image.
file /usr/bin/busybox | grep -q 'statically linked'
cp /usr/bin/busybox "$base/bin/busybox"
"$base/bin/busybox" --help > "$base/busybox-version.txt"
sha256sum "$base/bin/busybox" > "$base/busybox-sha256.txt"
archive="$base/make-4.4.1.tar.gz"
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz -o "$archive"
fi
printf '%s  %s\n' dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3 "$archive" | sha256sum -c -
mkdir "$base/make-static-build"
tar -xzf "$archive" -C "$base/make-static-build" --strip-components=1
cd "$base/make-static-build"
LDFLAGS=-static ./configure --disable-nls --without-guile > ../make-configure.log 2>&1
make -j "${JOBS:-2}" > ../make-build.log 2>&1
cp make "$base/bin/make"
"$base/bin/make" --version > "$base/make-version.txt"
sha256sum "$archive" "$base/bin/make" > "$base/make-sha256.txt"
echo "Static GNU Make ready: $base/bin/make"
