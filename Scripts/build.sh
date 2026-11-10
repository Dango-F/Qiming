#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${QIMING_BUILD_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 Scripts/manage_build_apps.py run ./Scripts/build.sh "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${1:-Debug}"
if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
  print -u2 'Usage: ./Scripts/build.sh [Debug|Release]'
  exit 2
fi
trap 'python3 Scripts/manage_build_apps.py cleanup' EXIT
signing=()
if [[ "${QIMING_UNSIGNED:-0}" == 1 ]]; then
  signing=(CODE_SIGNING_ALLOWED=NO)
elif [[ -n "${QIMING_TEAM_ID:-}" ]]; then
  signing=("DEVELOPMENT_TEAM=$QIMING_TEAM_ID")
fi
if [[ "$configuration" == Debug ]]; then
  # Match Xcode's own DerivedData location, so CLI and Cmd-R update the same Dev app.
  xcodebuild -project Qiming.xcodeproj -scheme Qiming -configuration Debug "${signing[@]}" build
else
  if [[ "${QIMING_UNSIGNED:-0}" == 1 ]]; then
    print -u2 'Unsigned UI previews use Debug; the installed Release must remain signed.'
    exit 2
  fi
  xcodebuild -project Qiming.xcodeproj -scheme Qiming -configuration Release \
    -derivedDataPath build/.ReleaseData.noindex "${signing[@]}" build
  python3 Scripts/manage_build_apps.py install build/.ReleaseData.noindex/Build/Products/Release/Qiming.app
  python3 Scripts/package_release.py /Applications/Qiming.app --output dist/Latest --refresh
  python3 Scripts/manage_build_apps.py verify-startup
fi
