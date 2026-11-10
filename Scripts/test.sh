#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${QIMING_BUILD_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 Scripts/manage_build_apps.py run ./Scripts/test.sh "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
trap 'python3 Scripts/manage_build_apps.py cleanup' EXIT
xcodebuild -project Qiming.xcodeproj -scheme Qiming -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/.TestData.noindex \
  CODE_SIGNING_ALLOWED=NO test
