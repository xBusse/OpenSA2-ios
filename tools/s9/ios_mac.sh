#!/bin/bash
# ios_mac.sh: the Mac half of the iOS build (docs/ios.md), from a checkout and the Linux half's archive
# (tools/s9/ios_inputs.py pack) to an unsigned .ipa. Run on a Mac, or on a CI macOS runner
# (tools/s9/ci/ios-build.yml).
#
#   bash tools/s9/ios_mac.sh [mac-inputs.tar.xz] [--team TEAMID] [--out DIR] [--install-deps]
#
# With an archive, it is unpacked into the checkout first (a later run without one reuses what is
# there: after a `git pull` that changed only the app, the runtime or the renderer, run it again
# with no archive). It then makes sure of what the archive cannot carry: Homebrew's tools
# (--install-deps installs any missing: cmake ninja llvm@20 gpatch python@3.13), a Python 3.10+
# .venv with the requirements, DXVK as a git checkout at its pin (the shader translator's build reads
# its commit), and the libpng tarball when the Linux machine could not fetch it. Then it links the
# game (with the code-patch tweaks when the archive has them), builds the app's libraries and Xcode
# project, and the .ipa: private/generated/s9/ios/SA2Recomp.ipa, copied to --out DIR when given.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"

ARCHIVE="" TEAM="" OUT="" INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --install-deps) INSTALL=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done
say() { printf '[ios_mac %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'IOS_MAC_REFUSED %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = Darwin ] || die "this is the Mac half: run it on macOS (the Linux half is tools/s9/ios_inputs.py)"
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "no iOS SDK: install Xcode and run 'sudo xcode-select -s /Applications/Xcode.app'"
command -v brew >/dev/null || die "no Homebrew: https://brew.sh"

# --- Homebrew's tools
missing=()
for f in cmake ninja llvm@20 gpatch python@3.13; do brew list --versions "$f" >/dev/null 2>&1 || missing+=("$f"); done
if [ ${#missing[@]} -gt 0 ] 2>/dev/null; then
  if [ "$INSTALL" = 1 ]; then say "brew install ${missing[*]}"; brew install ${missing[@]+"${missing[@]}"}
  else die "missing from Homebrew: ${missing[*]} (brew install ${missing[*]}, or run with --install-deps)"; fi
fi
LLVM="$(brew --prefix llvm@20)/bin"
PY313="$(brew --prefix python@3.13)/bin/python3.13"

# --- the .venv: Python 3.10 or later (Xcode's python3 is 3.9, which the requirements refuse)
if ! .venv/bin/python -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
  say "making .venv with $PY313"
  rm -rf .venv
  "$PY313" -m venv .venv
fi
if ! .venv/bin/python -c 'import iced_x86, pefile' 2>/dev/null; then
  .venv/bin/python -m pip install -q --upgrade pip
  .venv/bin/python -m pip install -q -r requirements.txt \
    || die "pip could not install the requirements (when it is iced-x86 building from source: brew install rust, then run again)"
fi

# --- the Linux half's archive
if [ -n "$ARCHIVE" ]; then
  [ -f "$ARCHIVE" ] || die "no archive $ARCHIVE"
  say "unpacking $(basename "$ARCHIVE")"
  tar -xJf "$ARCHIVE"
fi
[ -f private/generated/s9/ios/objects-double/summary.json ] \
  || die "no compiled game objects under private/generated/s9/ios: pass the Linux half's mac-inputs.tar.xz"

# --- DXVK as a git checkout at its pin
read -r DXVK_PATH DXVK_TAG DXVK_COMMIT DXVK_URL < <(.venv/bin/python -c '
import json; d = json.load(open("tools/pins.json"))["tools"]["dxvk"]
print(d["path"], d["tag"], d["commit"], d["url"])')
if [ "$(git -C "$DXVK_PATH" rev-parse HEAD 2>/dev/null || true)" != "$DXVK_COMMIT" ] \
   || [ "$(git -C "$DXVK_PATH" rev-parse --show-toplevel 2>/dev/null || true)" != "$ROOT/$DXVK_PATH" ]; then
  say "cloning DXVK $DXVK_TAG"
  rm -rf "$DXVK_PATH"
  git clone -q --branch "$DXVK_TAG" --recurse-submodules "$DXVK_URL" "$DXVK_PATH"
fi

# --- the libpng tarball
read -r PNG_PATH PNG_URL PNG_SHA < <(.venv/bin/python -c '
import json; d = json.load(open("tools/pins.json"))["tools"]["libpng"]
print(d["path"], d["url"], d["sha256"])')
if [ ! -f "$PNG_PATH" ] || [ "$(shasum -a 256 "$PNG_PATH" | cut -c1-64)" != "$PNG_SHA" ]; then
  say "fetching libpng"
  mkdir -p "$(dirname "$PNG_PATH")"
  curl -fsSL --retry 3 -o "$PNG_PATH" "$PNG_URL"
  [ "$(shasum -a 256 "$PNG_PATH" | cut -c1-64)" = "$PNG_SHA" ] || die "$PNG_URL is not the pinned libpng"
fi

# --- the game, the app, the .ipa
VARIANTS=()
[ -f private/generated/s9/ios/variants/variants.rec ] && VARIANTS=(--variants private/generated/s9/ios/variants)
say "linking the game"
.venv/bin/python tools/s9/ios_game.py link --llvm "$LLVM" ${VARIANTS[@]+"${VARIANTS[@]}"}
TEAMARG=()
[ -n "$TEAM" ] && TEAMARG=(--team "$TEAM")
say "building the app's libraries and Xcode project"
.venv/bin/python tools/s9/ios_app.py ${TEAMARG[@]+"${TEAMARG[@]}"}
say "building the .ipa"
.venv/bin/python tools/s9/ios_app.py --only ipa
IPA=private/generated/s9/ios/SA2Recomp.ipa
if [ -n "$OUT" ]; then mkdir -p "$OUT"; cp "$IPA" "$OUT/"; IPA="$OUT/SA2Recomp.ipa"; fi
say "IOS_MAC_OK $IPA ($(du -h "$IPA" | cut -f1))"
