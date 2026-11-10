#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${QIMING_BUILD_LOCK_HELD:-0}" != 1 ]]; then
  exec python3 Scripts/manage_build_apps.py run zsh ./Scripts/check_panel_presentation.sh "$@"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
trap 'rm -rf build/.PanelChecks.noindex' EXIT
mkdir -p build/.PanelChecks.noindex
xcrun swiftc -swift-version 6 -parse-as-library \
  Scripts/PanelPresentationChecks.swift Shared/Session.swift Shared/SystemPower.swift Qiming/UI/WingGeometry.swift \
  Qiming/UI/Components.swift Qiming/UI/GlassSurfaceView.swift \
  Qiming/UI/PanelController.swift Qiming/UI/GlassPopover.swift \
  -o build/.PanelChecks.noindex/PanelPresentationChecks
build/.PanelChecks.noindex/PanelPresentationChecks --expect-fixed "$@"
