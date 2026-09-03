#!/bin/zsh
set -euo pipefail

app_source_dir="${0:A:h}"
package_source_dir="${app_source_dir:h}"
repository_dir="$(cd "${package_source_dir}/../../.." && pwd)"
node_executable="$(command -v node)"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/proactive-ai-app.XXXXXX")"
bundle_path="${stage_dir}/Astra.app"
contents_path="${bundle_path}/Contents"
macos_path="${contents_path}/MacOS"
resources_path="${contents_path}/Resources"
install_dir="/Users/$(id -un)/Applications"
installed_bundle="${install_dir}/Astra.app"
legacy_bundle="${install_dir}/主动 AI.app"
signing_identity="${PROACTIVE_SIGNING_IDENTITY:-Proactive AI Local Code Signing}"

if ! security find-identity -v -p codesigning | grep -Fq "${signing_identity}"; then
  print -u2 -- "Missing code-signing identity: ${signing_identity}"
  exit 1
fi

cleanup() {
  rm -rf "${stage_dir}"
}
trap cleanup EXIT

mkdir -p "${macos_path}" "${resources_path}" "${install_dir}"
/usr/bin/swiftc \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreImage \
  -framework ScreenCaptureKit \
  -framework SwiftUI \
  -framework UserNotifications \
  -framework Vision \
  "${app_source_dir}/ProactiveAIApp.swift" \
  "${package_source_dir}/native/ScreenObserver.swift" \
  -o "${macos_path}/ProactiveAI"
cp "${app_source_dir}/Info.plist" "${contents_path}/Info.plist"
cp "${app_source_dir}/Assets/AppIcon.icns" "${resources_path}/AppIcon.icns"
print -r -- "${repository_dir}" > "${resources_path}/repository-path.txt"
print -r -- "${node_executable}" > "${resources_path}/node-path.txt"
/usr/bin/codesign --force --sign "${signing_identity}" "${bundle_path}"
if /usr/bin/pgrep -x ProactiveAI >/dev/null 2>&1; then
  /usr/bin/osascript -e 'tell application id "ai.deepseek.proactive.local" to quit' >/dev/null 2>&1 || true
  for _ in {1..40}; do
    /usr/bin/pgrep -x ProactiveAI >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
if /usr/bin/pgrep -x ProactiveAI >/dev/null 2>&1; then
  for app_pid in $(/usr/bin/pgrep -x ProactiveAI); do
    /usr/bin/pkill -TERM -P "${app_pid}" >/dev/null 2>&1 || true
    /bin/kill -TERM "${app_pid}" >/dev/null 2>&1 || true
  done
fi
if [[ -d "${installed_bundle}" ]]; then
  /bin/rm -rf "${installed_bundle}"
fi
/usr/bin/ditto "${bundle_path}" "${installed_bundle}"
/usr/bin/codesign --verify --deep --strict "${installed_bundle}"
if [[ -d "${legacy_bundle}" ]]; then
  /bin/rm -rf "${legacy_bundle}"
fi
if [[ "${PROACTIVE_SKIP_LAUNCH:-0}" != "1" ]]; then
  open "${installed_bundle}"
fi

print -r -- "Installed ${installed_bundle}"
