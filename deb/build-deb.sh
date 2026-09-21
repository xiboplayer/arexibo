#!/bin/bash
# Build arexibo DEB package
# Usage: ./deb/build-deb.sh <version> [release]
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [release]}"

# Parse version-release (e.g. 0.3.1-2 → version=0.3.1, release=2)
# $2 from shared workflow overrides parsed release
BASE_VERSION="${VERSION%%-*}"
if [[ -n "${2:-}" ]]; then
  RELEASE="$2"
elif [[ "$VERSION" == *-* ]]; then
  RELEASE="${VERSION#*-}"
else
  RELEASE="1"
fi

# Detect architecture
ARCH=$(dpkg --print-architecture)

echo "Building arexibo ${BASE_VERSION}-${RELEASE} for ${ARCH}"

# Build Rust binary
#
# rust-toolchain.toml pins the "stable" channel, but a distro cargo ignores
# it: Ubuntu 24.04 ships 1.75, and transitive dependencies now need the 2024
# edition (stable since 1.85). Bootstrap rustup when the available cargo is
# older than that, so every builder tracks the same channel the RPM build and
# `cargo test` already use.
#
# Debian trixie shipped 1.85, which used to clear this bar — until the
# 2026-09-06 Dependabot cargo bump (PR #93) pulled in time@0.3.47, whose MSRV
# is 1.88. trixie's system rustc doesn't build it: "error: rustc 1.85.1 is
# not supported by the following packages: time@0.3.47 requires rustc
# 1.88.0". Raise the floor so trixie also gets the rustup-installed stable
# toolchain instead of drifting out of sync with whatever MSRV Dependabot's
# next bump needs. Fedora is still left alone (system rustc tracks current
# stable closely enough not to fall behind crates.io).
MIN_CARGO_MINOR=88

cargo_too_old() {
  command -v cargo >/dev/null 2>&1 || return 0
  local version major minor
  version=$(cargo --version | awk '{print $2}')
  major=${version%%.*}
  minor=$(echo "$version" | cut -d. -f2)
  [ "$major" -eq 1 ] && [ "$minor" -lt "$MIN_CARGO_MINOR" ]
}

if cargo_too_old; then
  echo "==> cargo $(cargo --version 2>/dev/null | awk '{print $2}' || echo missing) predates the 2024 edition; installing the stable toolchain via rustup"
  export RUSTUP_HOME="${RUSTUP_HOME:-${PWD}/.rustup}"
  export CARGO_HOME="${CARGO_HOME:-${PWD}/.cargo}"
  curl --proto '=https' --tlsv1.2 --retry 5 --retry-connrefused -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
  export PATH="${CARGO_HOME}/bin:${PATH}"
fi

echo "==> building with $(cargo --version)"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
cargo build --release

# Create DEB package structure
PKG_DIR="deb-pkg/arexibo"
rm -rf deb-pkg
mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/bin"
mkdir -p "${PKG_DIR}/usr/share/doc/arexibo"
mkdir -p "${PKG_DIR}/usr/share/applications"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/256x256/apps"
mkdir -p "${PKG_DIR}/usr/share/icons/hicolor/scalable/apps"
mkdir -p "${PKG_DIR}/usr/lib/systemd/user"

# Install files
install -m755 target/release/arexibo "${PKG_DIR}/usr/bin/arexibo"
install -m644 arexibo.service "${PKG_DIR}/usr/lib/systemd/user/arexibo.service"
install -m644 LICENSE "${PKG_DIR}/usr/share/doc/arexibo/"
install -m644 README.md "${PKG_DIR}/usr/share/doc/arexibo/"
install -m644 CHANGELOG.md "${PKG_DIR}/usr/share/doc/arexibo/"
install -m644 arexibo.desktop "${PKG_DIR}/usr/share/applications/"
install -m644 assets/arexibo-256.png "${PKG_DIR}/usr/share/icons/hicolor/256x256/apps/arexibo.png"
install -m644 assets/logo.svg "${PKG_DIR}/usr/share/icons/hicolor/scalable/apps/arexibo.svg"

# Create control file
cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: arexibo
Version: ${BASE_VERSION}-${RELEASE}
Section: misc
Priority: optional
Architecture: ${ARCH}
Depends: libqt6webenginecore6, libqt6webenginewidgets6, libdbus-1-3, libzmq5
Maintainer: Pau Aliagas <pau@linuxnow.com>
Description: Rust-based digital signage player for Xibo CMS
 Arexibo is a Rust-based digital signage player compatible with Xibo CMS.
 It provides a lightweight alternative to the official Xibo player,
 designed for kiosk and digital signage deployments on Linux.
Homepage: https://github.com/birkenfeld/arexibo
EOF

# Build DEB
mkdir -p dist
dpkg-deb --build "${PKG_DIR}" "dist/arexibo_${BASE_VERSION}-${RELEASE}_${ARCH}.deb"

echo "Built DEBs:"
ls -lh dist/*.deb

# Clean up
rm -rf deb-pkg
