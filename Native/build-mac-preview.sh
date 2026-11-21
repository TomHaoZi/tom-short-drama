#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
output="$project/DerivedData/MacPreview"
source_icon="$project/Native/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc="${TOM_SWIFTC:-$(xcrun --sdk macosx --find swiftc)}"

mkdir -p "$output"
staging="$(mktemp -d "$output/.build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Tom短剧.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources" "$staging/AppIcon.iconset"

"$swiftc" -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
    -module-cache-path "$output/ModuleCache" -o "$bundle/Contents/MacOS/TomCinema" \
    "$project/Native/CinemaApp.swift" "$project/Native/MediaCatalog.swift" "$project/Native/Playback.swift" \
    "$project/Native/CatalogSync.swift" "$project/Native/ProductionCatalog.swift" "$project/Native/OnlineSearch.swift"

"$swiftc" -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
    -module-cache-path "$output/ModuleCache" -o "$staging/prepare-icon" "$project/Native/MacPreviewIcon.swift"
"$staging/prepare-icon" "$source_icon" "$staging/MacIcon.png"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$staging/MacIcon.png" --out "$staging/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$staging/MacIcon.png" --out "$staging/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$staging/AppIcon.iconset" -o "$resources/AppIcon.icns"
cp "$project/Native/catalog.json" "$project/Native/online-starter.json" "$resources/"
ditto "$project/assets" "$resources/assets"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Tom短剧</string>
    <key>CFBundleExecutable</key><string>TomCinema</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.tom.shortdrama.serialpreview</string>
    <key>CFBundleName</key><string>Tom短剧</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.6</string>
    <key>CFBundleVersion</key><string>12</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

destination="$output/Tom短剧.app"
previous="$staging/Previous.app"
if [[ -d "$destination" ]]; then mv "$destination" "$previous"; fi
if ! mv "$bundle" "$destination"; then
    if [[ -d "$previous" ]]; then mv "$previous" "$destination"; fi
    exit 1
fi
printf '%s\n' "$destination"
