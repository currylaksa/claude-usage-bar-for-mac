#!/usr/bin/env bash
# Claude Usage Bar — one-shot installer for macOS.
# Compiles the native Swift binary into a .app bundle (Spotlight-launchable)
# and registers a login agent. Re-running is safe (recompiles + reloads).
# Requires Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/ClaudeUsageBar.swift"
APP="$HOME/Applications/Claude Usage Bar.app"
BIN="$APP/Contents/MacOS/claude-usage-bar"
PLIST="$HOME/Library/LaunchAgents/com.wilderfarer.claude-usage-bar.plist"

command -v swiftc >/dev/null || {
    echo "swiftc not found — install Xcode Command Line Tools: xcode-select --install"
    exit 1
}

echo "→ Building $APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'INFOEOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.wilderfarer.claude-usage-bar</string>
    <key>CFBundleName</key>
    <string>Claude Usage Bar</string>
    <key>CFBundleExecutable</key>
    <string>claude-usage-bar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
INFOEOF
swiftc -O -parse-as-library -o "$BIN" "$SRC"

# Clean up previous install layouts (Python venv or bare binary).
rm -rf "$HOME/.claude-usage-bar"

echo "→ Writing login agent to $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wilderfarer.claude-usage-bar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-usage-bar.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-usage-bar.err</string>
</dict>
</plist>
PLISTEOF

echo "→ (Re)loading agent"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo
echo "✓ Done. Look for the widget in your menu bar."
echo "  First run: click it → 'Set session key…' → paste your claude.ai sessionKey."
echo "  Relaunch anytime: Spotlight → 'Claude Usage Bar', or:"
echo "    launchctl kickstart gui/\$(id -u)/com.wilderfarer.claude-usage-bar"
echo
echo "  Logs: /tmp/claude-usage-bar.log  and  /tmp/claude-usage-bar.err"
echo "  Uninstall: launchctl unload \"$PLIST\" && rm -rf \"$APP\" \"$PLIST\""
