#!/bin/zsh
set -u
cd "$(dirname "$0")"

VERSION="1.7.8"
SYSTEM_APP="/Applications/Largus Navigator.app"
USER_APP="$HOME/Applications/Largus Navigator.app"
FULL_LOG="$HOME/Desktop/LargusNavigator_build_full.log"
SHORT_LOG="$HOME/Desktop/LargusNavigator_install.log"
BUILD_LOG="$PWD/.largus_build.log"

: > "$SHORT_LOG"
log() { print -r -- "$1" | tee -a "$SHORT_LOG"; }
fail() {
  log ""
  log "❌ ОШИБКА: $1"
  if [ -f "$BUILD_LOG" ]; then
    log ""
    log "Последние ошибки сборки:"
    grep -E "error:|fatal error:|BUILD FAILED|Command .* failed" "$BUILD_LOG" | tail -n 20 | tee -a "$SHORT_LOG" || true
  fi
  log ""
  log "Короткий лог: $SHORT_LOG"
  log "Полный лог:   $FULL_LOG"
  read "?Нажмите Enter для выхода..."
  exit 1
}

clear
log "===================================================="
log " Largus Navigator — установка / обновление $VERSION"
log "===================================================="
log ""

log "[1/6] Проверка инструментов"
[ -d "/Applications/Xcode.app" ] || fail "Xcode не найден в /Applications/Xcode.app"
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer >/dev/null 2>&1 || fail "не удалось выбрать Xcode"
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    log "      Устанавливаю XcodeGen..."
    brew install xcodegen >>"$SHORT_LOG" 2>&1 || fail "не удалось установить XcodeGen"
  else
    fail "XcodeGen не найден и Homebrew отсутствует"
  fi
fi
log "      ✓ Xcode и XcodeGen готовы"

log "[2/6] Закрытие старой версии"
osascript -e 'tell application id "ru.denis.largusnavigator" to quit' >/dev/null 2>&1 || true
pkill -f "Largus Navigator.app/Contents/MacOS" >/dev/null 2>&1 || true
sleep 1
log "      ✓ закрыто"

log "[3/6] Чистая сборка 1.7.8"
rm -rf .release LargusNavigator.xcodeproj "$BUILD_LOG"
xcodegen generate --spec project.yml >"$BUILD_LOG" 2>&1 || { cp "$BUILD_LOG" "$FULL_LOG" 2>/dev/null || true; fail "XcodeGen не создал проект"; }

# Keep Xcode's very verbose output out of the user's Terminal.
# It remains available in full on the Desktop if something fails.
xcodebuild \
  -project LargusNavigator.xcodeproj \
  -scheme LargusNavigator \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .release \
  CODE_SIGNING_ALLOWED=NO \
  clean build >>"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
cp "$BUILD_LOG" "$FULL_LOG" 2>/dev/null || true
if [ $BUILD_STATUS -ne 0 ]; then
  fail "Xcode не смог собрать приложение"
fi
log "      ✓ BUILD SUCCEEDED"

SOURCE_APP="$PWD/.release/Build/Products/Release/Largus Navigator.app"
[ -d "$SOURCE_APP" ] || fail "собранный .app не найден"
SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "?")
[ "$SOURCE_VERSION" = "$VERSION" ] || fail "собрана версия $SOURCE_VERSION вместо $VERSION"
log "      ✓ собран Largus Navigator $SOURCE_VERSION"

log "[4/6] Удаление старых копий"
[ -d "$USER_APP" ] && rm -rf "$USER_APP"
if [ -d "$SYSTEM_APP" ]; then
  sudo rm -rf "$SYSTEM_APP" || fail "не удалось удалить старую копию из /Applications"
fi
log "      ✓ старые копии удалены"

log "[5/6] Установка в /Applications"
log "      macOS может запросить пароль администратора. Символы пароля не отображаются."
sudo /usr/bin/ditto "$SOURCE_APP" "$SYSTEM_APP" || fail "не удалось скопировать приложение в /Applications"
sudo /usr/bin/xattr -dr com.apple.quarantine "$SYSTEM_APP" >/dev/null 2>&1 || true
[ -d "$SYSTEM_APP" ] || fail "после копирования приложение отсутствует в /Applications"
INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SYSTEM_APP/Contents/Info.plist" 2>/dev/null || echo "?")
[ "$INSTALLED_VERSION" = "$VERSION" ] || fail "в /Applications установлена версия $INSTALLED_VERSION вместо $VERSION"
log "      ✓ /Applications/Largus Navigator.app = $INSTALLED_VERSION"

log "[6/6] Проверка единственной копии и запуск"
# Rebuild LaunchServices metadata and reveal the exact app we just installed.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SYSTEM_APP" >/dev/null 2>&1 || true
COPIES=$(mdfind "kMDItemCFBundleIdentifier == 'ru.denis.largusnavigator'" 2>/dev/null || true)
if [ -n "$COPIES" ]; then
  log "      Найденные копии:"
  while IFS= read -r item; do [ -n "$item" ] && log "      • $item"; done <<< "$COPIES"
fi
open -n "$SYSTEM_APP" || fail "не удалось запустить установленное приложение"
open -R "$SYSTEM_APP" >/dev/null 2>&1 || true
log ""
log "✅ ГОТОВО: Largus Navigator $VERSION установлен"
log "   $SYSTEM_APP"
log ""
log "Если версия в окне приложения отличается — запусти файл"
log "«Проверить установленную версию.command» из этой папки."
read "?Нажмите Enter, чтобы закрыть это окно..."
