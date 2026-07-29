#!/bin/zsh
clear
echo "Largus Navigator — проверка установленных копий"
echo "================================================"
for APP in "/Applications/Largus Navigator.app" "$HOME/Applications/Largus Navigator.app"; do
  if [ -d "$APP" ]; then
    V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    B=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
    echo "$APP"
    echo "  версия: $V  build: $B"
  else
    echo "$APP"
    echo "  нет"
  fi
done
echo
echo "Spotlight / LaunchServices:"
mdfind "kMDItemCFBundleIdentifier == 'ru.denis.largusnavigator'" 2>/dev/null || true
echo
read "?Нажмите Enter для выхода..."
