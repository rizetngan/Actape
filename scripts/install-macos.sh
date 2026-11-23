#!/bin/bash
set -euo pipefail

# Install the latest stable Actape release without a development toolchain.
# Use --download-only to verify the release without changing installed apps.
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS only." >&2
  exit 1
fi

repo="rizetngan/Actape"
echo "Checking the latest stable GitHub release..."
latest="$(curl --http1.1 -fLsS --retry 1 --connect-timeout 12 --max-time 45 -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
tag="${latest##*/}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not resolve a stable release tag: $tag" >&2
  exit 1
fi

name="Actape-macOS-${tag}-universal.zip"
base="https://github.com/$repo/releases/download/$tag"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $name..."
curl --http1.1 -fLsS --retry 2 --connect-timeout 12 --max-time 360 "$base/$name" -o "$tmp/$name"
curl --http1.1 -fLsS --retry 1 --connect-timeout 12 --max-time 60 "$base/SHA256SUMS.txt" -o "$tmp/SHA256SUMS.txt"

expected="$(awk -v name="$name" '$2 == name || $2 == "*" name {print $1}' "$tmp/SHA256SUMS.txt")"
if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Release checksum is missing or invalid." >&2
  exit 1
fi
actual="$(shasum -a 256 "$tmp/$name" | awk '{print $1}')"
if [[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "SHA-256 mismatch. Installation aborted." >&2
  exit 1
fi
echo "Verified $name (SHA-256: $actual)"

mkdir -p "$tmp/unpacked"
unzip -q "$tmp/$name" -d "$tmp/unpacked"
app="$(find "$tmp/unpacked" -maxdepth 5 -type d -name Actape.app -print -quit)"
if [[ -z "$app" || ! -d "$app/Contents" ]]; then
  echo "Actape.app not found in release ZIP." >&2
  exit 1
fi

if [[ "${1:-}" == "--download-only" ]]; then
  echo "Verification complete; no application was installed."
  exit 0
fi
if pgrep -x Actape >/dev/null; then
  echo "Please quit Actape before upgrading, then rerun this command." >&2
  exit 1
fi

if [[ -d "/Applications/Actape.app" ]]; then
  if [[ ! -w "/Applications" ]]; then
    echo "Actape is already installed in /Applications. Update it manually with administrator approval." >&2
    exit 1
  fi
  location="/Applications"
elif [[ -w "/Applications" ]]; then
  location="/Applications"
else
  location="$HOME/Applications"
fi

mkdir -p "$location"
target="$location/Actape.app"
backup=""
if [[ -e "$target" ]]; then
  backup_root="$HOME/Library/Application Support/Actape/App Backups"
  mkdir -p "$backup_root"
  backup="$backup_root/Actape-$(date +%Y%m%d-%H%M%S).app"
  ditto "$target" "$backup"
  rm -rf "$target"
fi

if ! ditto "$app" "$target"; then
  rm -rf "$target"
  if [[ -n "$backup" ]]; then
    ditto "$backup" "$target"
  fi
  echo "Installation failed; the previous application was restored when available." >&2
  exit 1
fi

echo "Installed Actape $tag to $target"
echo "Existing macros in Application Support were not modified."
open "$target" || echo "Open the app manually. macOS may request input/accessibility permissions."
