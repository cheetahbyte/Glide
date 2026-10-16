#!/bin/bash
# Usage: scripts/release.sh path/to/notarized/Glide.app
# Zips the app, signs the zip for Sparkle and adds it to appcast.xml.
set -euo pipefail

app="${1:?Pass the notarized Glide.app exported from Xcode}"
repo="cheetahbyte/Glide"
root="$(cd "$(dirname "$0")/.." && pwd)"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"

if grep -q "<sparkle:version>$build</sparkle:version>" "$root/appcast.xml"; then
    echo "Build $build is already in appcast.xml. Raise the build number in Xcode first." >&2
    exit 1
fi

xcrun stapler validate "$app" >/dev/null || { echo "$app is not notarized." >&2; exit 1; }

sign_update="$(find ~/Library/Developer/Xcode/DerivedData /tmp/glide-dd -path '*/artifacts/sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -1)"
[ -n "$sign_update" ] || { echo "sign_update not found. Build Glide in Xcode once so Sparkle is downloaded." >&2; exit 1; }

mkdir -p "$root/build"
zip="$root/build/Glide-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
signature="$("$sign_update" "$zip")"

item="        <item>
            <title>$version</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
            <enclosure url=\"https://github.com/$repo/releases/download/v$version/Glide-$version.zip\" $signature type=\"application/octet-stream\"/>
        </item>"

ITEM="$item" perl -0pi -e 's/( *<!-- items -->\n)/$1$ENV{ITEM}\n/' "$root/appcast.xml"

echo "Added $version ($build) to appcast.xml. To publish:"
echo "  gh release create v$version \"$zip\" --repo $repo --title \"Glide $version\""
echo "  git add appcast.xml && git commit -m \"Release $version\" && git push"
