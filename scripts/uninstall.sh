#!/usr/bin/env bash
# uninstall.sh — remove the SDL HIDAPI Vader 5 Pro override
#
# Removes whichever wiring the install script created:
#   - steam-launcher.service.d override.conf  (service mode)
#   - ~/.local/share/applications/steam.desktop  (desktop mode, if ours)
#   - /etc/udev/rules.d/60-vader5-sdl.rules
#   - ~/.local/share/vader5-driver/sdl/   (patched SDL)
#   - ~/.local/share/vader5-driver/wrapper.sh
#
# Does NOT remove SDL source or build dirs under ~/sdl-build/SDL.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
DIRECT_BACKUP_DIR="$DEPLOY_DIR/steam-backup"
STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
OVERRIDE="$HOME/.config/systemd/user/steam-launcher.service.d/override.conf"
USER_DESKTOP="$HOME/.local/share/applications/steam.desktop"
RESTART_STEAM=0

if [[ -f "$DIRECT_BACKUP_DIR/active" ]] \
        && ps -u "$UID" -o comm= | grep -Eq '^(steam|steamwebhelper)$'; then
    echo "[err ] close Steam completely before restoring the direct SDL installation." >&2
    exit 1
fi

# Service mode wiring
if [[ -f "$OVERRIDE" ]]; then
    rm -f "$OVERRIDE"
    systemctl --user daemon-reload
    ok "Removed systemd override"

    RESTART_STEAM=1
fi

# Desktop mode wiring — only remove if it was created by us.
if [[ -f "$USER_DESKTOP" ]] \
        && grep -Eq "X-Vader5Driver-Managed=true|vader5-driver" "$USER_DESKTOP" 2>/dev/null; then
    rm -f "$USER_DESKTOP"
    ok "Removed .desktop override"
fi

# Restore Steam's bundled SDL if direct deployment is active.
if [[ -f "$DIRECT_BACKUP_DIR/active" ]]; then
    for arch in 32 64; do
        steam_dir="$STEAM_ROOT/ubuntu12_$arch"
        backup_dir="$DIRECT_BACKUP_DIR/ubuntu12_$arch"
        if [[ -f "$backup_dir/libSDL3.so.0" ]]; then
            sudo cp -p "$backup_dir/libSDL3.so.0" "$steam_dir/libSDL3.so.0"
            ok "Restored Steam's $arch-bit SDL library"
        fi

        if [[ -f "$backup_dir/sdl3_shim.so" ]]; then
            sudo cp -p "$backup_dir/sdl3_shim.so" "$steam_dir/sdl3_shim.so"
        elif [[ -f "$backup_dir/sdl3_shim.absent" ]]; then
            sudo rm -f "$steam_dir/sdl3_shim.so"
        fi
    done
    rm -f "$DIRECT_BACKUP_DIR/active"
fi

# Udev rule
if [[ -f "/etc/udev/rules.d/60-vader5-sdl.rules" ]]; then
    sudo rm -f "/etc/udev/rules.d/60-vader5-sdl.rules"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    ok "Removed udev rule"
fi

# Boot-time xpad unbind service
if [[ -f "/etc/systemd/system/vader5-xpad-unbind.service" ]]; then
    sudo systemctl disable --now vader5-xpad-unbind.service
    sudo rm -f /etc/systemd/system/vader5-xpad-unbind.service /etc/vader5-xpad-unbind.sh
    sudo systemctl daemon-reload
    ok "Removed boot-time xpad unbind service"
fi
if [[ -f "/etc/vader5-xpad-unbind.sh" ]]; then
    sudo rm -f /etc/vader5-xpad-unbind.sh
fi

# Deployed artifacts
rm -rf "$DEPLOY_DIR/sdl"
rm -f "$DEPLOY_DIR/wrapper.sh"
# Remove artifacts from older installs if present
rm -f "$DEPLOY_DIR/steam-sdl-wrapper.sh" "$DEPLOY_DIR/sdl_intercept32.so" "$DEPLOY_DIR/sdl_intercept64.so"

if (( RESTART_STEAM )) && systemctl --user is-active steam-launcher.service &>/dev/null; then
    info "Restarting Steam without the override"
    systemctl --user restart steam-launcher.service
fi

ok "Removed deployed SDL. Replug the controller to restore default xpad binding. Uninstall complete."
