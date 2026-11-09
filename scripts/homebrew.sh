#!/bin/sh
# Writes Formula/whichdns.rb in the gstark/tap Homebrew tap for a published
# release, then commits and pushes the tap. The formula installs the prebuilt
# binary for the platform, so Homebrew does not need Zig.
#
# Usage: scripts/homebrew.sh [tag]   (default: the latest published release)
set -eu

REPO=gstark/whichdns
TAP=gstark/tap

tag=${1:-$(gh release view --repo "$REPO" --json tagName --jq .tagName)}
version=${tag#v}

checksums=$(gh release download "$tag" --repo "$REPO" --pattern checksums.txt --output -)
sha() {
  sha=$(printf '%s\n' "$checksums" | awk -v f="whichdns-$tag-$1.tar.gz" '$2 == f { print $1 }')
  [ -n "$sha" ] || { echo "No checksum for $1 in $tag" >&2; exit 1; }
  printf '%s' "$sha"
}
macos_arm64=$(sha macos-arm64)
macos_x86_64=$(sha macos-x86_64)
linux_arm64=$(sha linux-arm64)
linux_x86_64=$(sha linux-x86_64)

tap_dir=$(brew --repository "$TAP")
git -C "$tap_dir" pull --ff-only
/bin/mkdir -p "$tap_dir/Formula"
url="https://github.com/$REPO/releases/download/$tag/whichdns-$tag"
cat > "$tap_dir/Formula/whichdns.rb" <<EOF
class Whichdns < Formula
  desc "Benchmark DNS resolvers and rank them by reliability, then latency"
  homepage "https://github.com/$REPO"
  license "MIT"

  on_macos do
    on_arm do
      url "$url-macos-arm64.tar.gz"
      sha256 "$macos_arm64"
    end
    on_intel do
      url "$url-macos-x86_64.tar.gz"
      sha256 "$macos_x86_64"
    end
  end

  on_linux do
    on_arm do
      url "$url-linux-arm64.tar.gz"
      sha256 "$linux_arm64"
    end
    on_intel do
      url "$url-linux-x86_64.tar.gz"
      sha256 "$linux_x86_64"
    end
  end

  def install
    bin.install "whichdns"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/whichdns --version").strip
  end
end
EOF

git -C "$tap_dir" add Formula/whichdns.rb
if git -C "$tap_dir" diff --cached --quiet; then
  echo "Formula/whichdns.rb is already at $version."
  exit 0
fi
git -C "$tap_dir" commit -m "whichdns $version"
git -C "$tap_dir" push
echo "Published whichdns $version. Run 'brew install $TAP/whichdns' to install it."
