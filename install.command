#!/bin/bash
# MailDock 1.1 - builds the Mac app on this computer.
# Run from Terminal:  bash ~/Downloads/MailDock/install.command
DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="MailDock"
LOG="$HOME/Library/Logs/MailDock-install.log"
mkdir -p "$HOME/Library/Logs"
: > "$LOG"

echo ""
echo "=== Building $NAME ==="

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. A window will offer to install them."
  echo "Click Install, wait for it to finish, then run this command again."
  xcode-select --install 2>/dev/null || true
  exit 1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
SOURCES=("$DIR"/Sources/Core/*.swift "$DIR"/Sources/App/*.swift)

# Find every installed macOS SDK, newest first. The compiler and the newest SDK
# can be out of step after a partial update, so each is tried until one works.
SDKS=()
DEFAULT_SDK="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null)"
[ -n "$DEFAULT_SDK" ] && SDKS+=("$DEFAULT_SDK")
for d in "$(xcode-select -p)/SDKs" "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs" /Library/Developer/CommandLineTools/SDKs; do
  [ -d "$d" ] || continue
  while IFS= read -r s; do
    case " ${SDKS[*]} " in *" $s "*) ;; *) SDKS+=("$s") ;; esac
  done < <(ls -d "$d"/MacOSX[0-9]*.sdk 2>/dev/null | sort -r)
done
if [ ${#SDKS[@]} -eq 0 ]; then
  echo "No macOS SDK was found. Reinstall the Command Line Tools and try again."
  exit 1
fi

build_arch() {
  local arch="$1" sdk
  for sdk in "${SDKS[@]}"; do
    echo "--- $arch with $sdk" >> "$LOG"
    if xcrun swiftc -O -wmo -swift-version 5 -parse-as-library -module-name MailDock \
        -target "$arch-apple-macos14.0" -sdk "$sdk" \
        "${SOURCES[@]}" -o "$BUILD/$NAME-$arch" >> "$LOG" 2>&1; then
      echo "      $arch built with $(basename "$sdk") ✓"
      return 0
    fi
  done
  return 1
}

echo "[1/3] Compiling for Apple silicon and Intel (a few minutes the first time)…"
BUILT=()
for arch in arm64 x86_64; do
  if build_arch "$arch"; then BUILT+=("$BUILD/$NAME-$arch"); else echo "      $arch could not be built."; fi
done

THIS_ARCH="$(uname -m)"
if [ ${#BUILT[@]} -eq 0 ] || [ ! -x "$BUILD/$NAME-$THIS_ARCH" ]; then
  echo ""
  echo "Build failed. Please send Claude this file: $LOG"
  grep -E "error:" "$LOG" | sort -u | head -10
  exit 1
fi

echo "[2/3] Making the app…"
APP="$BUILD/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ${#BUILT[@]} -eq 2 ]; then
  lipo -create "${BUILT[@]}" -output "$APP/Contents/MacOS/$NAME"
else
  cp "${BUILT[0]}" "$APP/Contents/MacOS/$NAME"
  echo "      Note: this copy only runs on $THIS_ARCH Macs."
fi
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >> "$LOG" 2>&1

echo "[3/3] Installing…"
mkdir -p "$HOME/Applications"
TARGET="$HOME/Applications/$NAME.app"
if pgrep -x "$NAME" >/dev/null 2>&1; then
  osascript -e "quit app \"$NAME\"" 2>/dev/null || true
  sleep 1
fi
rm -rf "$TARGET"
ditto "$APP" "$TARGET"

echo ""
echo "Installed: $TARGET"
echo "Drag it from the Finder window to the Dock."
open -R "$TARGET"
open "$TARGET"
