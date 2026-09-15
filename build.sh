#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build"
app="$build/QuackDuckJVM.app"
jre="$app/jre"
cache="$root/.cache/jre17"

rm -rf "$build"
mkdir -p "$app/classes" "$cache"

if [[ ! -f "$cache/release" ]]; then
  curl -fL --retry 3 \
    https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip \
    -o "$cache/jre.zip"
  unzip -q "$cache/jre.zip" -d "$cache"
  tar -xf "$cache"/jre17-*.tar.xz -C "$cache"
  rm "$cache/jre.zip" "$cache"/jre17-*.tar.xz
fi

cp -R "$cache" "$jre"
javac -d "$app/classes" "$root/java/Hello.java"

sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang \
  -arch arm64 -mios-simulator-version-min=14.0 -fobjc-arc \
  -isysroot "$sdk" "$root/src/main.m" \
  -framework UIKit -framework Foundation \
  -o "$app/QuackDuckJVM"

cp "$root/Info.plist" "$app/Info.plist"

while IFS= read -r -d '' file; do
  if file "$file" | grep -q 'Mach-O'; then
    xcrun vtool -arch arm64 -set-build-version 7 14.0 16.0 \
      -replace -output "$file.patched" "$file"
    mv "$file.patched" "$file"
    chmod +x "$file"
    codesign --force --sign - "$file"
  fi
done < <(find "$jre" -type f -print0)

codesign --force --deep --sign - "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$build/QuackDuckJVM.zip"

