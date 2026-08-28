#!/bin/sh
# Installs the latest (or a pinned) ReyCode release for the current platform.
#
#   REYCODE_VERSION=v0.1.0 REYCODE_INSTALL_DIR=~/.reycode REYCODE_BIN_DIR=~/.local/bin \
#     curl -fsSL https://raw.githubusercontent.com/Reyane-R/ReyCode/main/install.sh | sh
set -eu

REPO="Reyane-R/ReyCode"
VERSION="${REYCODE_VERSION:-latest}"
INSTALL_DIR="${REYCODE_INSTALL_DIR:-$HOME/.reycode}"
BIN_DIR="${REYCODE_BIN_DIR:-$HOME/.local/bin}"

case "$(uname -s)" in
  Darwin) os="macos" ;;
  Linux) os="linux" ;;
  *)
    echo "reycode install: unsupported OS '$(uname -s)' (macOS and Linux only)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) arch="aarch64" ;;
  x86_64) arch="x86_64" ;;
  *)
    echo "reycode install: unsupported architecture '$(uname -m)'" >&2
    exit 1
    ;;
esac

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -H "User-Agent: reycode-install" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --header="User-Agent: reycode-install" "$1"
  else
    echo "reycode install: need curl or wget to download releases" >&2
    exit 1
  fi
}

download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 -H "User-Agent: reycode-install" -o "$2" "$1"
  else
    wget -qO "$2" --header="User-Agent: reycode-install" "$1"
  fi
}

if [ "$VERSION" = "latest" ]; then
  VERSION=$(fetch "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$VERSION" ]; then
    echo "reycode install: could not resolve the latest release" >&2
    exit 1
  fi
fi
asset="reycode-${VERSION#v}-${os}-${arch}.tar.gz"
url="https://github.com/${REPO}/releases/download/${VERSION}/${asset}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Installing ReyCode ${VERSION} (${os}-${arch})"
download "$url" "${tmp}/${asset}"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tar -xzf "${tmp}/${asset}" -C "$tmp"
rm -rf "$INSTALL_DIR"
mv "${tmp}/reycode-${VERSION#v}" "$INSTALL_DIR"

cat > "${BIN_DIR}/reycode" <<EOF
#!/bin/sh
if [ \$# -eq 0 ]; then
  set -- start
fi
exec "${INSTALL_DIR}/bin/rey_code" "\$@"
EOF
chmod +x "${BIN_DIR}/reycode"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "Add ${BIN_DIR} to your PATH, e.g.:"
    echo "  echo 'export PATH=\"${BIN_DIR}:\$PATH\"' >> ~/.zshrc"
    ;;
esac

echo "Installed. Run 'reycode' to start."
