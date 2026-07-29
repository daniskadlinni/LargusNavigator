#!/bin/zsh
set -e
cd "$(dirname "$0")"

echo "========================================"
echo "  Largus Navigator — настройка проекта"
echo "========================================"
echo

XCODE_APP=""
if [ -d "/Applications/Xcode.app" ]; then
  XCODE_APP="/Applications/Xcode.app"
else
  XCODE_APP=$(find /Applications -maxdepth 1 -type d -name "Xcode*.app" | head -n 1)
fi

if [ -z "$XCODE_APP" ]; then
  echo "Xcode не найден в папке /Applications."
  echo "Распакуйте Xcode 26.2 Universal и перенесите Xcode.app в «Программы»."
  read "?Нажмите Enter для выхода..."
  exit 1
fi

echo "Найден Xcode: $XCODE_APP"
sudo xcode-select -s "$XCODE_APP/Contents/Developer"

echo
xcodebuild -version
echo

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Устанавливаю XcodeGen..."
    brew install xcodegen
  else
    echo "Не найден Homebrew."
    echo "Установите Homebrew с brew.sh, затем выполните:"
    echo "  brew install xcodegen"
    read "?Нажмите Enter для выхода..."
    exit 1
  fi
fi

rm -rf LargusNavigator.xcodeproj .build
xcodegen generate --spec project.yml

echo
echo "Проверяю сборку..."
xcodebuild \
  -project LargusNavigator.xcodeproj \
  -scheme LargusNavigator \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO \
  build

echo
echo "Проект создан и успешно собран."
open -a "$XCODE_APP" LargusNavigator.xcodeproj
