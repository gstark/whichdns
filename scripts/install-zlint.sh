#!/usr/bin/env sh
# Install a checksum-verified ZLint release into the project's ignored cache.
set -eu

version=0.10.0
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$root_dir/.zig-cache/tools"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        target=macos-aarch64
        checksum=9dcc4b27f450c7ba6707403283b9a44092a41b777356ec7326a611bd9ec67200
        ;;
    Darwin-x86_64)
        target=macos-x86_64
        checksum=59f6ad25c625dabdfb4bed6cb640e400c4235fdd5475608966060e548c208b3b
        ;;
    Linux-aarch64|Linux-arm64)
        target=linux-aarch64
        checksum=ec5e31eacc889540dbfa0a32f0e694199d06c16f640b832bf2a3bd8ecc07c3e3
        ;;
    Linux-x86_64)
        target=linux-x86_64
        checksum=0b331646d5e40bec3cfcb0694c5da0b13b9de8b10af12937a777ab3144b70b65
        ;;
    *)
        echo 'Unsupported platform; see https://github.com/DonIsaac/zlint/releases/tag/v0.10.0' >&2
        exit 1
        ;;
esac

mkdir -p "$install_dir"
download=$(mktemp "$install_dir/zlint.XXXXXX")
trap 'rm -f "$download"' EXIT HUP INT TERM
curl -fL --retry 3 "https://github.com/DonIsaac/zlint/releases/download/v$version/zlint-$target" -o "$download"
if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$checksum" "$download" | sha256sum -c -
else
    printf '%s  %s\n' "$checksum" "$download" | shasum -a 256 -c -
fi
chmod +x "$download"
mv "$download" "$install_dir/zlint"
"$install_dir/zlint" --version
