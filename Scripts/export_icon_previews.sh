#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
qiming_developer="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
qiming_icon_tool="${qiming_developer:h}/Applications/Icon Composer.app/Contents/Executables/ictool"
qiming_output="$PWD/design-assets/qiming-icon-v2/exports"
mkdir -p "$qiming_output"
for rendition in Default Dark TintedLight TintedDark; do
  "$qiming_icon_tool" "$PWD/Qiming/Resources/AppIcon.icon" --export-image \
    --output-file "$qiming_output/Qiming-native-${rendition}-1024.png" \
    --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 \
    --tint-color 0.58 --tint-strength 0.35 > /dev/null
done
for size in 16 32 64 128 256 512; do
  "$qiming_icon_tool" "$PWD/Qiming/Resources/AppIcon.icon" --export-image \
    --output-file "$qiming_output/Qiming-native-Default-${size}.png" \
    --platform macOS --rendition Default --width "$size" --height "$size" --scale 1 > /dev/null
done
mkdir -p "$qiming_output/Qiming.iconset"
for points in 16 32 128 256 512; do
  for density in 1 2; do
    pixels=$((points*density))
    suffix=""
    if [[ "$density" == 2 ]]; then suffix="@2x"; fi
    cp "$qiming_output/Qiming-native-Default-${pixels}.png" \
      "$qiming_output/Qiming.iconset/icon_${points}x${points}${suffix}.png"
  done
done
iconutil -c icns "$qiming_output/Qiming.iconset" -o "$qiming_output/Qiming.icns"
