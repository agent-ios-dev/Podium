#!/bin/zsh
set -e
cd "$(dirname "$0")"
OUT=../../Podium/Resources/GuestTools/podium_netd.bin
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xcrun --sdk iphoneos clang -target armv7-apple-ios6.0 -marm -Os -c podium_netd.c -o "$TMP/netd.o"
xcrun ld -arch armv7 -platform_version ios 6.0 6.0 -e _main "$TMP/netd.o" libSystem.tbd -o "$TMP/unsigned"
xcrun codesign_allocate -i "$TMP/unsigned" -a armv7 4096 -o "$TMP/signed"
python3 ../keybag_bootstrap/legacy_adhoc_sign.py "$TMP/signed" com.podium.netd ../podium_syncd/entitlements.plist
cp "$TMP/signed" "$OUT"
