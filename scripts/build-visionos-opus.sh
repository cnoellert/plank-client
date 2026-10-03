#!/usr/bin/env bash
# Build the pinned libopus used by the native visionOS Client's Host-audio
# decoder. The source archive is verified against the xiph.org SHA-256 before
# it is unpacked; a mismatch stops the build.
#
#   scripts/build-visionos-opus.sh device|simulator|macos <prefix> [work-dir]
#
# "macos" builds a host copy for the focused decoder tests only.
set -euo pipefail

readonly OPUS_VERSION=1.6.1
readonly OPUS_SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
readonly OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
readonly DEPLOYMENT_TARGET="${PLANK_VISIONOS_DEPLOYMENT_TARGET:-26.0}"

if [[ $# -lt 2 ]]; then
    echo "usage: $0 device|simulator|macos <prefix> [work-dir]" >&2
    exit 2
fi
platform=$1
prefix=$2
work=${3:-"${prefix}.work"}

case "$platform" in
device) platform_args=(-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros
                       -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET") ;;
simulator) platform_args=(-DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xrsimulator
                          -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET") ;;
macos) platform_args=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0) ;;
*) echo "unknown platform: $platform" >&2; exit 2 ;;
esac

mkdir -p "$work"
archive="$work/opus-${OPUS_VERSION}.tar.gz"
if [[ ! -f "$archive" ]]; then
    curl -fsSL --retry 3 -o "$archive.partial" "$OPUS_URL"
    mv "$archive.partial" "$archive"
fi
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ "$actual" != "$OPUS_SHA256" ]]; then
    echo "opus-${OPUS_VERSION}.tar.gz checksum mismatch: $actual" >&2
    exit 1
fi

source_dir="$work/opus-${OPUS_VERSION}"
rm -rf "$source_dir" "$work/build-$platform"
tar -xzf "$archive" -C "$work"

cmake -S "$source_dir" -B "$work/build-$platform" -G Ninja \
    "${platform_args[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_C_FLAGS=-ffile-prefix-map=$HOME=/build/user -ffile-prefix-map=$work=/build/dependencies/opus" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_DRED=OFF \
    -DOPUS_OSCE=OFF \
    -DOPUS_CUSTOM_MODES=OFF \
    -DOPUS_FIXED_POINT=OFF \
    -DOPUS_ENABLE_FLOAT_API=ON
cmake --build "$work/build-$platform"
cmake --install "$work/build-$platform"
printf 'libopus %s (%s) installed for %s at %s\n' \
    "$OPUS_VERSION" "$OPUS_SHA256" "$platform" "$prefix"
