#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

xcrun --sdk iphoneos clang -target armv7-apple-ios6.0 -marm -Os -fPIC \
    -fno-stack-protector -c substrate_probe.c -o "$tmp/probe.o"
xcrun ld -dylib -arch armv7 -platform_version ios 6.0 6.0 \
    -install_name /Library/MobileSubstrate/DynamicLibraries/PodiumInjectionProbe.dylib \
    "$tmp/probe.o" ../podium_netd/libSystem.tbd -o "$tmp/probe.unsigned"
xcrun codesign_allocate -i "$tmp/probe.unsigned" -a armv7 4096 -o "$tmp/probe.signed"
python3 ../keybag_bootstrap/legacy_adhoc_sign.py "$tmp/probe.signed" com.podium.substrate-probe
cp "$tmp/probe.signed" build/PodiumInjectionProbe.dylib
echo "Built $(pwd)/build/PodiumInjectionProbe.dylib"
