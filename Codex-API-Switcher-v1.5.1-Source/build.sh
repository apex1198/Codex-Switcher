#!/bin/zsh
set -eu

project_dir="${0:A:h}"
requested_profile="${1:-all}"

build_profile() {
  local target="$1"
  local app_name bundle_id app_dir

  case "$target" in
    switcher)
      app_name="Codex API Switcher"
      bundle_id="com.alexcrearive.codex-api-switcher"
      ;;
    subscription)
      app_name="ChatGPT Subscription"
      bundle_id="com.alexcrearive.chatgpt.subscription"
      ;;
    api)
      app_name="ChatGPT API"
      bundle_id="com.alexcrearive.chatgpt.api"
      ;;
    *)
      print -u2 "Unknown target: $target"
      exit 2
      ;;
  esac

  app_dir="$project_dir/build/$app_name.app"
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

  /usr/bin/swiftc "$project_dir/Sources/Switcher.swift" \
    -o "$app_dir/Contents/MacOS/$app_name" \
    -framework Cocoa \
    -framework Security

  /bin/cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleDisplayName -string "$app_name" "$app_dir/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleName -string "$app_name" "$app_dir/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleExecutable -string "$app_name" "$app_dir/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_dir/Contents/Info.plist"
  /bin/cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

  /usr/bin/xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
  /usr/bin/xattr -cr "$app_dir"
  /usr/bin/codesign --force --deep --sign - "$app_dir"
  /usr/bin/xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
  /usr/bin/xattr -cr "$app_dir"
  /usr/bin/codesign --verify --deep --strict "$app_dir"

  print "Built: $app_dir"

  # If target is switcher and /Applications/Codex API Switcher.app exists, update it too
  if [[ "$target" == "switcher" && -d "/Applications/Codex API Switcher.app" ]]; then
    /bin/rm -rf "/Applications/Codex API Switcher.app"
    /bin/cp -R "$app_dir" "/Applications/Codex API Switcher.app"
    /usr/bin/xattr -d com.apple.FinderInfo "/Applications/Codex API Switcher.app" 2>/dev/null || true
    /usr/bin/xattr -cr "/Applications/Codex API Switcher.app"
    /usr/bin/codesign --force --deep --sign - "/Applications/Codex API Switcher.app"
    /usr/bin/codesign --verify --deep --strict "/Applications/Codex API Switcher.app"
    print "Updated: /Applications/Codex API Switcher.app"
  fi
}

case "$requested_profile" in
  switcher|subscription|api) build_profile "$requested_profile" ;;
  all)
    build_profile switcher
    build_profile subscription
    build_profile api
    ;;
  *)
    print -u2 "Usage: ./build.sh [switcher|subscription|api|all]"
    exit 2
    ;;
esac
