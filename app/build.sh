#!/bin/sh
set -eu
cd "$(dirname "$0")"
version=1.5.1
build_number=66
if [ "${RELEASE_TAG:-v$version}" != "v$version" ]; then
    echo "Release tag must match the app version: v$version" >&2
    exit 1
fi
mkdir -p .build
work=$(mktemp -d .build/compile.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir "$work/artifacts"
sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
    app="$work/$arch/Peek.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app/Contents/Resources/"
    cp Resources/AppIcon-1024.png "$app/Contents/Resources/AppIcon-1024.png"
    cp Resources/MenuBarIcon-64.png "$app/Contents/Resources/MenuBarIcon-64.png"
    cp Resources/AppIcon.icns "$app/Contents/Resources/PeekIcon.icns"
    xcrun swiftc -O -sdk "$sdk" -target "$arch-apple-macos13.0" \
        main.swift DiagnosticLog.swift RecoveryJournal.swift DockPresenceController.swift ApplicationRecallMemory.swift Localization.swift MainWindow.swift AppBinding.swift GlobalShortcutManager.swift WindowController.swift WindowSpaces.swift HoverController.swift PeekMark.swift \
        -o "$app/Contents/MacOS/Peek" -framework AppKit -framework ApplicationServices -framework Carbon -framework ServiceManagement
    test "$(xcrun lipo -archs "$app/Contents/MacOS/Peek")" = "$arch"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Peek</string><key>CFBundleIdentifier</key><string>dev.local.Peek</string><key>CFBundleName</key><string>Peek</string><key>CFBundleDisplayName</key><string>Peek</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleDevelopmentRegion</key><string>en</string><key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array><key>CFBundleVersion</key><string>$build_number</string><key>PeekAuthor</key><string>yinyu985</string><key>PeekAuthorURL</key><string>https://github.com/yinyu985</string><key>LSUIElement</key><true/><key>NSQuitAlwaysKeepsWindows</key><false/><key>CFBundleShortVersionString</key><string>$version</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>CFBundleIconFile</key><string>PeekIcon</string><key>NSAccessibilityUsageDescription</key><string>控制绑定窗口；选择隐藏整个应用时隐藏该应用的所有窗口。</string></dict></plist>
PLIST
    if [ -n "${DEVELOPER_ID_APPLICATION:-}${NOTARY_PROFILE:-}" ]; then
        : "${DEVELOPER_ID_APPLICATION:?Developer ID Application identity required}" "${NOTARY_PROFILE:?notarytool keychain profile required}"
        case "$DEVELOPER_ID_APPLICATION" in 'Developer ID Application: '*) ;; *) echo 'Expected Developer ID Application identity' >&2; exit 1;; esac
        codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
        ditto -c -k --keepParent "$app" "$work/$arch.zip"
        xcrun notarytool submit "$work/$arch.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$app"
        xcrun stapler validate "$app"
    else
        codesign --force --sign - --identifier dev.local.Peek --requirements '=designated => identifier "dev.local.Peek"' "$app"
    fi
    codesign --verify --strict "$app"

    # Each disk image contains its native app and a drag-to-install shortcut.
    staging="$work/$arch/dmg"
    mkdir "$staging"
    ditto "$app" "$staging/Peek.app"
    ln -s /Applications "$staging/Applications"
    image="Peek-$version-$arch.dmg"
    hdiutil create -volname Peek -srcfolder "$staging" -format UDZO -fs HFS+ "$work/artifacts/$image"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        codesign --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$work/artifacts/$image"
        xcrun notarytool submit "$work/artifacts/$image" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$work/artifacts/$image"
        xcrun stapler validate "$work/artifacts/$image"
    fi
    hdiutil verify "$work/artifacts/$image"
    (cd "$work/artifacts" && shasum -a 256 "$image" > "$image.sha256")
done

# Publish only after both packages pass. Failed builds leave existing output alone.
for arch in arm64 x86_64; do
    mkdir -p ".build/$arch"
    rm -rf ".build/$arch/Peek.app"
    mv "$work/$arch/Peek.app" ".build/$arch/Peek.app"
done
mv "$work/artifacts/"* .build/
# Retire the old combined output so it cannot be uploaded by mistake.
rm -rf .build/Peek.app
rm -f .build/Peek-*-universal.dmg .build/Peek-*-universal.dmg.sha256
printf 'Built app/.build/Peek-%s-arm64.dmg and Peek-%s-x86_64.dmg\n' "$version" "$version"
