#!/usr/bin/env bash
# Install a Swift 6.0.3 toolchain on Ubuntu 24.04 (x86_64) without root-level
# package installs. Prefers the official swift.org tarball; if that host is not
# reachable (e.g. restricted egress), falls back to Ubuntu's `swiftlang` .deb
# from the Ubuntu archive plus the libxml2.so.16 it links against.
#
# Usage: scripts/install-swift-linux.sh [prefix]   (default prefix /opt/swift)
set -euo pipefail
PREFIX="${1:-/opt/swift}"
BIN=/usr/local/bin

if command -v swift >/dev/null 2>&1; then
  echo "swift already installed: $(swift --version 2>&1 | head -1)"; exit 0
fi
mkdir -p "$PREFIX"; cd "$PREFIX"

OFFICIAL=https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04.tar.gz
if curl -fsSL -o swift.tgz "$OFFICIAL"; then
  tar xzf swift.tgz --strip-components=1
  for b in "$PREFIX"/usr/bin/*; do ln -sf "$b" "$BIN/$(basename "$b")"; done
else
  echo "swift.org unreachable; using Ubuntu archive swiftlang 6.0.3"
  POOL=http://archive.ubuntu.com/ubuntu/pool
  curl -fsSLO "$POOL/universe/s/swiftlang/swiftlang_6.0.3-2build1_amd64.deb"
  curl -fsSLO "$POOL/universe/s/swiftlang/libswiftlang_6.0.3-2build1_amd64.deb"
  curl -fsSLO "$POOL/main/libx/libxml2/libxml2-16_2.14.5+dfsg-0.2_amd64.deb"
  dpkg -x swiftlang_6.0.3-2build1_amd64.deb root
  dpkg -x libswiftlang_6.0.3-2build1_amd64.deb root
  dpkg -x libxml2-16_2.14.5+dfsg-0.2_amd64.deb xml
  cp -a xml/usr/lib/x86_64-linux-gnu/libxml2.so.16* /usr/local/lib/ && ldconfig
  for b in swift swiftc swift-build swift-test swift-run swift-package swift-frontend swift-driver; do
    ln -sf "$PREFIX/root/usr/libexec/swift/bin/$b" "$BIN/$b"
  done
  rm -f ./*.deb
fi
swift --version
