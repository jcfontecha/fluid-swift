#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
device=${1:-CCB6A9E7-B40B-475E-82F3-EDE71EA740F9}
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --package-path Benchmarks -c release --product FluidBench --triple arm64-apple-ios18.0-simulator --sdk "$sdk"
bin=$(swift build --package-path Benchmarks -c release --triple arm64-apple-ios18.0-simulator --sdk "$sdk" --show-bin-path)
app=Benchmarks/.build/FluidBench.app
mkdir -p "$app"
cp "$bin/FluidBench" "$app/FluidBench"
cp Benchmarks/container.json "$app/container.json"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.fluid.benchmark</string>
<key>CFBundleExecutable</key><string>FluidBench</string>
<key>CFBundleName</key><string>FluidBench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
if ! xcrun simctl list devices booted | rg -q "$device"; then xcrun simctl boot "$device"; fi
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
python3 Benchmarks/run.py simulator --device "$device"
