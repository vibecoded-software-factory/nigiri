#!/bin/sh
# Build, install and (re)start nigiri as a launchd agent.
#
# Hard-won TCC lessons (one afternoon of popup hell, condensed):
# - An UNBUNDLED binary is a second-class TCC citizen: entries pile up as
#   indistinguishable rows, grants pin to per-build hashes, and running it
#   from a terminal silently borrows the TERMINAL's grant (which is why
#   dev runs "worked" while the launchd agent didn't - launchd makes the
#   binary responsible for itself).
# - A real .app bundle (what AeroSpace/Rectangle ship) is keyed by bundle
#   id: ONE row in the panel, resettable with `tccutil reset Accessibility
#   dev.nigiri`, and the grant is re-attachable by flipping the same row.
# - The permission dialog must be rate-limited in code (Permissions.swift
#   prompts at most once per boot for the agent): KeepAlive + prompt =
#   popup firehose.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="$HOME/Applications/Nigiri.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/nigiri "$APP/Contents/MacOS/nigiri"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.nigiri</string>
    <key>CFBundleName</key><string>Nigiri</string>
    <key>CFBundleExecutable</key><string>nigiri</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
# Sign with the self-signed "nigiri codesign" certificate when present:
# a REAL identity gives TCC a stable anchor, so the Accessibility grant
# survives every rebuild (ad-hoc pins to per-build cdhash and dies with
# each install - proven painfully). Fallback to ad-hoc only if the cert
# is missing.
if security find-identity -v -p codesigning | grep -q "nigiri codesign"; then
    codesign --force --sign "nigiri codesign" --identifier dev.nigiri "$APP"
else
    echo "WARNING: no 'nigiri codesign' certificate - ad-hoc signature (the grant will die on every rebuild)"
    codesign --force --sign - "$APP"
fi

# The same binary doubles as the CLI (`nigiri msg ...` needs no grant).
mkdir -p "$HOME/.local/bin"
cp .build/release/nigiri "$HOME/.local/bin/nigiri"

PLIST="$HOME/Library/LaunchAgents/dev.nigiri.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.nigiri</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/nigiri</string>
        <string>tile</string>
        <string>--apps</string>
        <string>all</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>StandardOutPath</key><string>/tmp/nigiri.log</string>
    <key>StandardErrorPath</key><string>/tmp/nigiri.log</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
# KeepAlive on FAILURE only: crashes (and the missing-grant exit) respawn
# - the agent self-heals the moment the checkbox is ticked - while the
# deliberate `quit` action (exit 0) stays quit. launchd's SIGTERM on
# bootout runs the stashed-window restore.

launchctl bootout "gui/$(id -u)/dev.nigiri" 2>/dev/null || true
pkill -f 'nigiri tile' 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Nigiri.app installed and started (log: /tmp/nigiri.log)"
echo "if it asks for permission: it is ONE 'nigiri' row in Accessibility - tick it once"
echo "config is live: ~/.config/niri/config.kdl (or ~/.config/nigiri/config.kdl if no niri config exists) - this script is only needed after code changes"