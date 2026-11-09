#!/usr/bin/env sh
# Install a checksum-verified Zig release into the project's ignored cache.
# In GitHub Actions, the Zig directory is also added to PATH for later steps.
set -eu

version=0.16.0
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$root_dir/.zig-cache/tools/zig-$version"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        target=aarch64-macos
        checksum=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
        ;;
    Darwin-x86_64)
        target=x86_64-macos
        checksum=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
        ;;
    Linux-aarch64|Linux-arm64)
        target=aarch64-linux
        checksum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
        ;;
    Linux-x86_64)
        target=x86_64-linux
        checksum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
        ;;
    *)
        echo "Unsupported platform; see https://ziglang.org/download/#release-$version" >&2
        exit 1
        ;;
esac

if [ ! -x "$install_dir/zig" ]; then
    mkdir -p "$(dirname "$install_dir")"
    download=$(mktemp "$(dirname "$install_dir")/zig.XXXXXX")
    trap 'rm -f "$download"' EXIT HUP INT TERM
    curl -fL --retry 3 "https://ziglang.org/download/$version/zig-$target-$version.tar.xz" -o "$download"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\n' "$checksum" "$download" | sha256sum -c -
    else
        printf '%s  %s\n' "$checksum" "$download" | shasum -a 256 -c -
    fi
    rm -rf "$install_dir"
    mkdir -p "$install_dir"
    tar -xJf "$download" -C "$install_dir" --strip-components=1
fi

if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
fi
"$install_dir/zig" version
