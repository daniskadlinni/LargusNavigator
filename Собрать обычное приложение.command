#!/bin/zsh
set -e
cd "$(dirname "$0")"

echo "========================================"
echo " Largus Navigator — обычное приложение"
echo "========================================"
echo

if [ ! -d "/Applications/Xcode.app" ]; then
  echo "Xcode не найден в /Applications."
  read "?Нажмите Enter для выхода..."
  exit 1
fi

sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen не найден. Сначала запустите «Создать и открыть проект.command»."
  read "?Нажмите Enter для выхода..."
  exit 1
fi

xcodegen generate --spec project.yml
rm -rf .release

xcodebuild \
  -project LargusNavigator.xcodeproj \
  -scheme LargusNavigator \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .release \
  CODE_SIGNING_ALLOWED=NO \
  build

SOURCE_APP=".release/Build/Products/Release/Largus Navigator.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/Largus Navigator.app"

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --force --deep --sign - "$TARGET_APP" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

echo
echo "Готово: $TARGET_APP"
echo "Теперь приложение можно запускать без Xcode."
open "$TARGET_APP"
open "$TARGET_DIR"
