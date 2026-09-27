#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build"
app="$build/QuackDuckJVM.app"
jre="$app/jre"
cache="$root/.cache/jre17"
amethyst="$root/.cache/amethyst"
runelite_version="${RUNELITE_VERSION:-1.12.37}"
runelite_url="${RUNELITE_JAR_URL:-https://repo.runelite.net/net/runelite/client/$runelite_version/client-$runelite_version-shaded.jar}"
platform="${IOS_PLATFORM:-iphonesimulator}"
case "$platform" in
  iphonesimulator) target_flag=-mios-simulator-version-min=14.0; platform_code=7 ;;
  iphoneos) target_flag=-miphoneos-version-min=14.0; platform_code=2 ;;
  *) echo "Unsupported IOS_PLATFORM: $platform" >&2; exit 1 ;;
esac

rm -rf "$build"
mkdir -p "$app/classes" "$app/libs" "$app/libs_caciocavallo17" "$cache"

if [[ ! -f "$cache/release" ]]; then
  curl -fL --retry 3 \
    https://assets.angelauramc.dev/openjdk/ios-arm64/jre17-ios-aarch64.zip \
    -o "$cache/jre.zip"
  unzip -q "$cache/jre.zip" -d "$cache"
  tar -xf "$cache"/jre17-*.tar.xz -C "$cache"
  rm "$cache/jre.zip" "$cache"/jre17-*.tar.xz
fi

cp -R "$cache" "$jre"

mkdir -p "$jre/lib/fonts"
curl -fL --retry 3 \
  'https://raw.githubusercontent.com/google/fonts/main/ofl/notosans/NotoSans%5Bwdth,wght%5D.ttf' \
  -o "$jre/lib/fonts/NotoSans.ttf"

if [[ ! -d "$amethyst/.git" ]]; then
  git clone --depth 1 https://github.com/AngelAuraMC/Amethyst-iOS.git "$amethyst"
fi
cp "$amethyst"/JavaApp/libs/caciocavallo17/*.jar "$app/libs_caciocavallo17/"

if [[ ! -f "$root/.cache/client-$runelite_version-shaded.jar" ]]; then
  curl -fL --retry 3 "$runelite_url" -o "$root/.cache/client-$runelite_version-shaded.jar"
fi
cp "$root/.cache/client-$runelite_version-shaded.jar" "$app/libs/runelite.jar"
javac -d "$app/classes" \
  "$root/java/Launcher.java" \
  "$root/java/net/runelite/client/util/LinkBrowser.java"

sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
# The downloaded runtime is device-tagged. Simulator builds retag it before
# linking the Caciocavallo shim, then retag the remaining runtime libraries.
if [[ "$platform" == iphonesimulator ]]; then
  xcrun vtool -arch arm64 -set-build-version "$platform_code" 14.0 16.0 -replace \
    -output "$jre/lib/libawt_headless.dylib.sim" "$jre/lib/libawt_headless.dylib"
  mv "$jre/lib/libawt_headless.dylib.sim" "$jre/lib/libawt_headless.dylib"
fi
xcrun --sdk "$platform" clang -dynamiclib \
  -arch arm64 "$target_flag" -fobjc-arc \
  -isysroot "$sdk" -I"$amethyst/Natives" \
  "$amethyst/Natives/awt_xawt/xawt_fake.m" \
  -L"$jre/lib" -lawt_headless -Wl,-rpath,@loader_path \
  -Wl,-install_name,@rpath/libawt_xawt.dylib \
  -o "$jre/lib/libawt_xawt.dylib"

xcrun --sdk "$platform" clang \
  -arch arm64 "$target_flag" -fobjc-arc \
  -isysroot "$sdk" -I"$amethyst/Natives" \
  "$root/src/main.m" \
  -framework UIKit -framework Foundation -framework AVFoundation -framework Security \
  -framework QuartzCore -framework CoreGraphics \
  -o "$app/QuackDuckJVM"

cp "$root/Info.plist" "$app/Info.plist"

while IFS= read -r -d '' file; do
  if file "$file" | grep -q 'Mach-O'; then
    if [[ "$platform" == iphonesimulator ]]; then
      xcrun vtool -arch arm64 -set-build-version "$platform_code" 14.0 16.0 \
        -replace -output "$file.patched" "$file"
      mv "$file.patched" "$file"
    fi
    chmod +x "$file"
    codesign --force --sign - "$file"
  fi
done < <(find "$jre" -type f -print0)

codesign --force --deep --sign - "$app"
if [[ "$platform" == iphoneos ]]; then
  mkdir -p "$build/Payload"
  cp -R "$app" "$build/Payload/"
  (cd "$build" && zip -qr QuackDuckJVM-unsigned.ipa Payload)
else
  ditto -c -k --sequesterRsrc --keepParent "$app" "$build/QuackDuckJVM.zip"
fi
