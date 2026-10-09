#!/usr/bin/env bash
# Install the SDL HIDAPI Vader 5 Pro override for Steam.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    echo "       It installs into your \$HOME. Re-run as your own user." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"

SDL_REF="${SDL_REF:-release-3.4.4}"
SDL_SRC="${SDL_SRC:-$HOME/sdl-build/SDL-3.4.4}"
SDL_REPO_URL="https://github.com/libsdl-org/SDL.git"
BUILD_MODE="${VADER5_BUILD_MODE:-sniper}"
SNIPER_SDK_IMAGE="${SNIPER_SDK_IMAGE:-registry.gitlab.steamos.cloud/steamrt/sniper/sdk}"

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
SDL_DEPLOY_DIR="$DEPLOY_DIR/sdl"
OLD_WRAPPER_DST="$DEPLOY_DIR/wrapper.sh"
STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
DIRECT_BACKUP_DIR="$DEPLOY_DIR/steam-backup"
UDEV_RULE_SRC="$REPO_ROOT/60-vader5-sdl.rules"
UDEV_RULE_DST="/etc/udev/rules.d/60-vader5-sdl.rules"
XPAD_SCRIPT_SRC="$REPO_ROOT/scripts/vader5-xpad-unbind.sh"
XPAD_SCRIPT_DST="/etc/vader5-xpad-unbind.sh"
XPAD_SERVICE_SRC="$REPO_ROOT/scripts/vader5-xpad-unbind.service"
XPAD_SERVICE_DST="/etc/systemd/system/vader5-xpad-unbind.service"
PATCH_FILE="$REPO_ROOT/sdl-flydigi-vader5-linux.patch"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err ]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 [--build sniper|native] [--deploy direct]

  --build   Build in the Steam Runtime Sniper SDK (default), or natively.
  --deploy  Replace Steam's SDL libraries directly (the default).

Equivalent environment variables: VADER5_BUILD_MODE and SNIPER_SDK_IMAGE.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            [[ $# -ge 2 ]] || { err "Missing value for --build"; usage >&2; exit 2; }
            BUILD_MODE="$2"
            shift 2
            ;;
        --deploy)
            [[ $# -ge 2 ]] || { err "Missing value for --deploy"; usage >&2; exit 2; }
            [[ "$2" == "direct" ]] \
                || { err "Only direct deployment is supported."; usage >&2; exit 2; }
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

case "$BUILD_MODE" in
    sniper|native) ;;
    *) err "Invalid build mode '$BUILD_MODE' (expected sniper or native)"; exit 2 ;;
esac
# ── Distro + package manager detection ───────────────────────────────────────

PKG_MANAGER=""
PKG_INSTALL=""
PKG_CONFIG_32=""
X11_32_LIB=""
X11_INCLUDE=""

detect_env() {
    if command -v pacman &>/dev/null; then
        PKG_MANAGER=pacman
        PKG_INSTALL="sudo pacman -S --needed --noconfirm"
        PKG_CONFIG_32="/usr/lib32/pkgconfig"
        X11_32_LIB="/usr/lib32/libX11.so"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER=dnf
        PKG_INSTALL="sudo dnf install -y"
        if [[ -d /usr/lib32/pkgconfig ]]; then
            PKG_CONFIG_32="/usr/lib32/pkgconfig"
            X11_32_LIB="/usr/lib32/libX11.so"
        else
            PKG_CONFIG_32="/usr/lib/pkgconfig"
            X11_32_LIB="/usr/lib/libX11.so"
        fi
    elif command -v apt-get &>/dev/null; then
        PKG_MANAGER=apt
        PKG_INSTALL="sudo apt-get install -y"
        PKG_CONFIG_32="/usr/lib/i386-linux-gnu/pkgconfig"
        X11_32_LIB="/usr/lib/i386-linux-gnu/libX11.so"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER=zypper
        PKG_INSTALL="sudo zypper install -y"
        PKG_CONFIG_32="/usr/lib/pkgconfig"
        X11_32_LIB="/usr/lib32/libX11.so"
    else
        warn "Unknown package manager — you may need to install build deps manually"
    fi

    if [[ -d /usr/include/X11 ]]; then
        X11_INCLUDE="/usr/include"
    fi

    if [[ -n "$X11_32_LIB" && ! -f "$X11_32_LIB" ]]; then
        local found
        found="$(ldconfig -p 2>/dev/null \
            | awk '/libX11\.so.*ELF32|libX11\.so.*i386/{print $NF; exit}')"
        [[ -n "$found" ]] && X11_32_LIB="$found"
    fi

    if [[ -n "$PKG_MANAGER" ]]; then
        info "Detected package manager: $PKG_MANAGER"
    fi
}

# ── Steam launcher detection ──────────────────────────────────────────────────

STEAM_LAUNCHER=""

detect_steam() {
    for p in \
        /usr/lib/steamos/steam-launcher \
        /usr/bin/steam \
        /usr/games/steam \
        "$HOME/.local/share/Steam/steam.sh"; do
        if [[ -x "$p" ]]; then
            STEAM_LAUNCHER="$p"
            ok "Steam launcher: $STEAM_LAUNCHER"
            return
        fi
    done

    if flatpak list 2>/dev/null | grep -q 'com.valvesoftware.Steam'; then
        err "Flatpak Steam detected. This script does not support Flatpak Steam."
        err "Install Steam as a native package or use the standalone installer."
        exit 1
    fi

    err "Cannot find Steam. Install Steam and re-run."
    exit 1
}

# ── Steam launch environment detection ────────────────────────────────────────
# Used only to report whether to restart the service or relaunch from desktop.

WIRE_MODE=""
STEAM_DESKTOP_SRC=""

detect_wiring_mode() {
    if systemctl --user cat steam-launcher.service &>/dev/null; then
        WIRE_MODE=service
        info "Steam launch environment: systemd service"
        return
    fi

    for p in \
        /usr/share/applications/steam.desktop \
        /usr/lib/steam/steam.desktop \
        /usr/local/share/applications/steam.desktop; do
        if [[ -f "$p" ]]; then
            STEAM_DESKTOP_SRC="$p"
            WIRE_MODE=desktop
            info "Steam launch environment: desktop entry ($p)"
            return
        fi
    done

    if [[ -n "$STEAM_LAUNCHER" ]]; then
        WIRE_MODE=desktop
        warn "No system steam.desktop found; Steam launcher detected"
        return
    fi

    err "Cannot determine how to wire Steam. Report this at the project repo."
    exit 1
}

# ── Prerequisites check ───────────────────────────────────────────────────────

MISSING_TOOLS=()

check_tool() {
    command -v "$1" &>/dev/null || MISSING_TOOLS+=("$1")
}

install_deps() {
    [[ ${#MISSING_TOOLS[@]} -eq 0 ]] && return

    warn "Missing tools: ${MISSING_TOOLS[*]}"

    if [[ -z "$PKG_MANAGER" ]]; then
        err "Cannot auto-install — install the missing tools manually and re-run."
        exit 1
    fi

    local pkgs=()
    case "$PKG_MANAGER" in
        pacman)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)    pkgs+=(cmake) ;;
                    ninja)    pkgs+=(ninja) ;;
                    git)      pkgs+=(git) ;;
                    patch)    pkgs+=(patch) ;;
                    gcc)      pkgs+=(gcc gcc-multilib) ;;
                    patchelf) pkgs+=(patchelf) ;;
                    podman)   pkgs+=(podman) ;;
                    readelf)  pkgs+=(binutils) ;;
                esac
            done
            ;;
        dnf)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)    pkgs+=(cmake) ;;
                    ninja)    pkgs+=(ninja-build) ;;
                    git)      pkgs+=(git) ;;
                    patch)    pkgs+=(patch) ;;
                    gcc)      pkgs+=(gcc glibc-devel.i686 libstdc++-devel.i686) ;;
                    patchelf) pkgs+=(patchelf) ;;
                    podman)   pkgs+=(podman) ;;
                    readelf)  pkgs+=(binutils) ;;
                esac
            done
            ;;
        apt)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)    pkgs+=(cmake) ;;
                    ninja)    pkgs+=(ninja-build) ;;
                    git)      pkgs+=(git) ;;
                    patch)    pkgs+=(patch) ;;
                    gcc)      pkgs+=(gcc gcc-multilib) ;;
                    patchelf) pkgs+=(patchelf) ;;
                    podman)   pkgs+=(podman) ;;
                    readelf)  pkgs+=(binutils) ;;
                esac
            done
            ;;
        zypper)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)    pkgs+=(cmake) ;;
                    ninja)    pkgs+=(ninja) ;;
                    git)      pkgs+=(git) ;;
                    patch)    pkgs+=(patch) ;;
                    gcc)      pkgs+=(gcc gcc-32bit) ;;
                    patchelf) pkgs+=(patchelf) ;;
                    podman)   pkgs+=(podman) ;;
                    readelf)  pkgs+=(binutils) ;;
                esac
            done
            ;;
    esac

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "Installing: ${pkgs[*]}"
        $PKG_INSTALL "${pkgs[@]}"
    fi
}

install_x11_32() {
    # Only needed for the 32-bit SDL cmake build
    if [[ -n "$X11_32_LIB" && -f "$X11_32_LIB" ]]; then
        return
    fi

    warn "32-bit libX11 not found at $X11_32_LIB"
    [[ -z "$PKG_MANAGER" ]] && { err "Install 32-bit X11 dev libs manually and re-run."; exit 1; }

    case "$PKG_MANAGER" in
        pacman)  $PKG_INSTALL lib32-libx11 lib32-libxext lib32-glibc lib32-gcc-libs ;;
        dnf)     # Fedora / Bazzite / Nobara — SDL's 32-bit cmake probe pulls
                 # in the full X11 i686 dev surface, not just libX11/libXext.
                 # Reported by RavioliAM (issue #2) on Nobara 43.
                 $PKG_INSTALL \
                     glibc-devel.i686 libstdc++-devel.i686 \
                     libX11-devel.i686 libXext-devel.i686 \
                     libXcursor-devel.i686 libXi-devel.i686 \
                     libXfixes-devel.i686 libXrandr-devel.i686 \
                     libXrender-devel.i686 libXinerama-devel.i686 \
                     libXScrnSaver-devel.i686 libXtst-devel.i686 ;;
        apt)     sudo dpkg --add-architecture i386 2>/dev/null || true
                 sudo apt-get update -qq
                 $PKG_INSTALL \
                     libx11-dev:i386 libxext-dev:i386 \
                     libxcursor-dev:i386 libxi-dev:i386 \
                     libxfixes-dev:i386 libxrandr-dev:i386 \
                     libxrender-dev:i386 libxinerama-dev:i386 \
                     libxss-dev:i386 libxtst-dev:i386 ;;
        zypper)  $PKG_INSTALL libX11-devel-32bit ;;
    esac

    # Re-probe after install
    if [[ ! -f "$X11_32_LIB" ]]; then
        local found
        found="$(ldconfig -p 2>/dev/null \
            | awk '/libX11\.so.*ELF32|libX11\.so.*i386/{print $NF; exit}')"
        [[ -n "$found" ]] && X11_32_LIB="$found"
    fi
}

# ── SDL cmake flags ───────────────────────────────────────────────────────────
# Minimal Steam-client profile: video + X11 + OpenGL for the client UI,
# HIDAPI + joystick for controller support, everything else off.
# MinSizeRel + strip keeps the library well under Steam's original file sizes.
# RUNPATH=$ORIGIN matches what Valve ships so Steam's module loader is happy.

SDL_CMAKE_COMMON=(
    -GNinja
    -DCMAKE_BUILD_TYPE=MinSizeRel
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    "-DCMAKE_INSTALL_RPATH=\$ORIGIN"
    -DCMAKE_SKIP_BUILD_RPATH=OFF
    -DBUILD_SHARED_LIBS=ON
    -DSDL_SHARED=ON -DSDL_STATIC=OFF
    -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
    -DSDL_INSTALL_TESTS=OFF -DSDL_INSTALL_DOCS=OFF
    -DSDL_AUDIO=OFF -DSDL_CAMERA=OFF -DSDL_DIALOG=OFF
    -DSDL_GPU=OFF -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=OFF
    -DSDL_OPENGLES=OFF -DSDL_PIPEWIRE=OFF -DSDL_PULSEAUDIO=OFF
    -DSDL_SNDIO=OFF -DSDL_WAYLAND=OFF -DSDL_TRAY=OFF -DSDL_VULKAN=OFF
    -DSDL_DBUS=OFF -DSDL_IBUS=OFF -DSDL_FRIBIDI=OFF -DSDL_LIBTHAI=OFF
    -DSDL_JACK=OFF -DSDL_ALSA=OFF
    -DSDL_HAPTIC=ON -DSDL_SENSOR=ON
    -DSDL_HIDAPI=ON -DSDL_HIDAPI_JOYSTICK=ON -DSDL_HIDAPI_LIBUSB=ON
    -DSDL_JOYSTICK=ON -DSDL_VIRTUAL_JOYSTICK=ON
    -DSDL_VIDEO=ON -DSDL_RENDER=ON -DSDL_OPENGL=ON
    -DSDL_X11=ON -DSDL_X11_SHARED=ON
)

# ── Build helpers ─────────────────────────────────────────────────────────────

_verify_sdl() {
    local lib="$1" bits="$2"
    if ! LC_ALL=C readelf -d "$lib" 2>/dev/null | grep -q 'RUNPATH.*\$ORIGIN'; then
        warn "$lib is missing RUNPATH=\$ORIGIN — Steam's loader may not handle it correctly"
    fi
    local class
    class="$(LC_ALL=C readelf -h "$lib" 2>/dev/null | awk '/Class:/{print $2}')"
    if [[ "$bits" == "32" && "$class" != "ELF32" ]]; then
        err "$lib is $class, expected ELF32"
        exit 1
    fi
    if [[ "$bits" == "64" && "$class" != "ELF64" ]]; then
        err "$lib is $class, expected ELF64"
        exit 1
    fi
}

_verify_shim_dependency() {
    local lib="$1"
    if ! LC_ALL=C readelf -d "$lib" 2>/dev/null | grep -q 'NEEDED.*sdl3_shim\.so'; then
        err "$lib does not declare the required sdl3_shim.so dependency"
        exit 1
    fi
}

_find_sdl_versioned() {
    find "$1" -maxdepth 1 -name 'libSDL3.so.0.*' | head -1
}

# ── Remove wrapper wiring left by older installer versions ────────────────────

remove_wrapper_wiring() {
    local override_file="$HOME/.config/systemd/user/steam-launcher.service.d/override.conf"
    local dst="$HOME/.local/share/applications/steam.desktop"

    if [[ -f "$override_file" ]] && grep -Fq "$OLD_WRAPPER_DST" "$override_file"; then
        rm -f "$override_file"
        systemctl --user daemon-reload
        ok "Removed the old systemd wrapper override"
    fi

    if [[ -f "$dst" ]] \
            && { grep -q '^X-Vader5Driver-Managed=true$' "$dst" \
                || grep -Fq "$OLD_WRAPPER_DST" "$dst"; }; then
        if [[ -n "$STEAM_DESKTOP_SRC" ]]; then
            rm -f "$dst"
        else
            awk -v launcher="$STEAM_LAUNCHER" '
                in_entry && /^Exec=/ { print "Exec=" launcher " %U"; next }
                /^\\[Desktop Entry\\]$/ { in_entry = 1 }
                /^X-Vader5Driver-Managed=true$/ { next }
                { print }
            ' "$dst" > "$dst.tmp"
            mv "$dst.tmp" "$dst"
        fi
        ok "Removed the old desktop wrapper override"
    fi

    rm -f "$OLD_WRAPPER_DST"
}

prepare_backup_permissions() {
    local uid gid backup_dir backup_file
    uid="$(id -u)"
    gid="$(id -g)"

    sudo install -d -o "$uid" -g "$gid" -m 700 \
        "$DIRECT_BACKUP_DIR" \
        "$DIRECT_BACKUP_DIR/ubuntu12_32" \
        "$DIRECT_BACKUP_DIR/ubuntu12_64"

    for backup_dir in "$DIRECT_BACKUP_DIR/ubuntu12_32" "$DIRECT_BACKUP_DIR/ubuntu12_64"; do
        for backup_file in \
            "$backup_dir/libSDL3.so.0" \
            "$backup_dir/sdl3_shim.so" \
            "$backup_dir/sdl3_shim.absent" \
            "$backup_dir/sdl3_shim.installed.sha256"; do
            if [[ -e "$backup_file" ]]; then
                sudo chown "$uid:$gid" "$backup_file"
                chmod u+rw "$backup_file"
            fi
        done
    done
    if [[ -e "$DIRECT_BACKUP_DIR/active" ]]; then
        sudo chown "$uid:$gid" "$DIRECT_BACKUP_DIR/active"
        chmod u+rw "$DIRECT_BACKUP_DIR/active"
    fi
}

deploy_direct() {
    local lib32="$STEAM_ROOT/ubuntu12_32/libSDL3.so.0"
    local lib64="$STEAM_ROOT/ubuntu12_64/libSDL3.so.0"
    local shim32="$STEAM_ROOT/ubuntu12_32/sdl3_shim.so"
    local shim64="$STEAM_ROOT/ubuntu12_64/sdl3_shim.so"
    local backup32="$DIRECT_BACKUP_DIR/ubuntu12_32/libSDL3.so.0"
    local backup64="$DIRECT_BACKUP_DIR/ubuntu12_64/libSDL3.so.0"
    local size32 size64 patched32 patched64

    for _path in "$lib32" "$lib64"; do
        [[ -f "$_path" ]] || { err "Steam SDL library not found: $_path"; exit 1; }
    done

    size32="$(stat -c %s "$lib32")"
    size64="$(stat -c %s "$lib64")"
    patched32="$(stat -c %s "$SDL_DEPLOY_DIR/libSDL3-32.so.0")"
    patched64="$(stat -c %s "$SDL_DEPLOY_DIR/libSDL3-64.so.0")"
    if (( patched32 > size32 || patched64 > size64 )); then
        err "Patched SDL is larger than Steam's library; refusing direct deployment."
        err "32-bit: $patched32 / $size32 bytes; 64-bit: $patched64 / $size64 bytes."
        exit 1
    fi

    prepare_backup_permissions
    if ! readelf -d "$lib32" 2>/dev/null | grep -q 'NEEDED.*sdl3_shim\.so'; then
        cp -p "$lib32" "$backup32"
    fi
    if ! readelf -d "$lib64" 2>/dev/null | grep -q 'NEEDED.*sdl3_shim\.so'; then
        cp -p "$lib64" "$backup64"
    fi

    for _arch in 32 64; do
        _steam_shim="$STEAM_ROOT/ubuntu12_$_arch/sdl3_shim.so"
        _backup_dir="$DIRECT_BACKUP_DIR/ubuntu12_$_arch"
        _installed_hash="$_backup_dir/sdl3_shim.installed.sha256"
        _current_backup="$_backup_dir/sdl3_shim.so"
        _absent_marker="$_backup_dir/sdl3_shim.absent"
        if [[ -e "$_steam_shim" ]]; then
            _current_hash="$(sha256sum "$_steam_shim" | awk '{print $1}')"
            if [[ -f "$_installed_hash" ]] \
                    && [[ "$_current_hash" == "$(cat "$_installed_hash")" ]]; then
                continue
            fi
            cp -p "$_steam_shim" "$_current_backup"
            rm -f "$_absent_marker"
        elif [[ -f "$_installed_hash" ]]; then
            rm -f "$_current_backup"
            touch "$_absent_marker"
        elif [[ ! -e "$_current_backup" && ! -e "$_absent_marker" ]]; then
            touch "$_absent_marker"
        fi
    done

    touch "$DIRECT_BACKUP_DIR/active"
    sudo install -m 644 "$SDL_DEPLOY_DIR/libSDL3-64.so.0" "$lib64"
    sudo truncate -s "$size64" "$lib64"
    sudo chown --reference="$backup64" "$lib64"
    sudo install -m 644 "$SDL_DEPLOY_DIR/libSDL3-32.so.0" "$lib32"
    sudo truncate -s "$size32" "$lib32"
    sudo chown --reference="$backup32" "$lib32"
    sudo install -m 644 "$SDL_DEPLOY_DIR/sdl3_shim64.so" "$shim64"
    sudo chown --reference="$backup64" "$shim64"
    sudo install -m 644 "$SDL_DEPLOY_DIR/sdl3_shim32.so" "$shim32"
    sudo chown --reference="$backup32" "$shim32"
    sha256sum "$shim32" | awk '{print $1}' \
        > "$DIRECT_BACKUP_DIR/ubuntu12_32/sdl3_shim.installed.sha256"
    sha256sum "$shim64" | awk '{print $1}' \
        > "$DIRECT_BACKUP_DIR/ubuntu12_64/sdl3_shim.installed.sha256"
    [[ "$(stat -c %s "$lib64")" == "$size64" ]] \
        || { err "64-bit Steam SDL padding did not preserve the original size"; exit 1; }
    [[ "$(stat -c %s "$lib32")" == "$size32" ]] \
        || { err "32-bit Steam SDL padding did not preserve the original size"; exit 1; }
    ok "Patched SDL installed directly to Steam and padded to the existing library sizes"
}

# ── Main ──────────────────────────────────────────────────────────────────────

detect_env
detect_steam
for _arch in 32 64; do
    if [[ ! -f "$STEAM_ROOT/ubuntu12_${_arch}/libSDL3.so.0" ]]; then
        err "Steam SDL library not found under $STEAM_ROOT/ubuntu12_${_arch}"
        exit 1
    fi
done
if ps -u "$UID" -o comm= | grep -Eq '^(steam|steamwebhelper)$'; then
    err "Steam is running. Close Steam completely before direct SDL replacement, then re-run."
    exit 1
fi
detect_wiring_mode

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites (build: $BUILD_MODE, deploy: direct)"
check_tool git
check_tool patch
check_tool readelf
if [[ "$BUILD_MODE" == "sniper" ]]; then
    check_tool podman
else
    check_tool gcc
    check_tool cmake
    check_tool ninja
    check_tool patchelf
fi
install_deps

for tool in "${MISSING_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        err "Required tool '$tool' is still missing after dependency installation."
        exit 1
    fi
done

if [[ "$BUILD_MODE" == "native" ]] \
        && ! echo 'int main(){}' | gcc -m32 -x c - -o /dev/null 2>/dev/null; then
    warn "gcc -m32 is unavailable — the native 32-bit SDL build will fail"
fi
ok "Prerequisites satisfied"

# ── 2. SDL source ─────────────────────────────────────────────────────────────
info "SDL source: $SDL_SRC"

if [[ ! -d "$SDL_SRC/.git" ]]; then
    info "Cloning SDL $SDL_REF into $SDL_SRC"
    mkdir -p "$(dirname "$SDL_SRC")"
    git clone --quiet --branch "$SDL_REF" --depth 1 "$SDL_REPO_URL" "$SDL_SRC"
    ok "SDL cloned"
else
    info "SDL source already present at $SDL_SRC"
fi

# Apply patch if the key symbol isn't already there
if grep -q 'SDL_HIDAPI_Flydigi_UsesUnnumbered32ByteReports' \
        "$SDL_SRC/src/joystick/hidapi/SDL_hidapi_flydigi.c" 2>/dev/null; then
    ok "Flydigi Linux patch already applied"
else
    info "Applying Flydigi Linux patch"
    if ! patch -N -p1 -d "$SDL_SRC" < "$PATCH_FILE"; then
        err "Patch failed to apply. The SDL source may be at a different version."
        err "Check $PATCH_FILE against $SDL_SRC/src/joystick/hidapi/SDL_hidapi_flydigi.c"
        exit 1
    fi
    ok "Patch applied"
fi

SDL64_VERSIONED=""
SDL32_VERSIONED=""
BUILD_OUTPUT=""

if [[ "$BUILD_MODE" == "sniper" ]]; then
    info "Pulling Steam Runtime Sniper SDK: $SNIPER_SDK_IMAGE"
    podman pull "$SNIPER_SDK_IMAGE"
    BUILD_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/vader5-sdl.XXXXXX")"
    trap 'if [[ -n "$BUILD_OUTPUT" ]]; then rm -rf "$BUILD_OUTPUT"; fi' EXIT
    info "Building patched SDL in the Sniper SDK"
    podman run --rm --security-opt label=disable \
        --volume "$SDL_SRC:/src/SDL:ro" \
        --volume "$REPO_ROOT:/src/repo:ro" \
        --volume "$BUILD_OUTPUT:/out:rw" \
        "$SNIPER_SDK_IMAGE" \
        bash /src/repo/scripts/build-sdl-sniper.sh
    SDL64_VERSIONED="$BUILD_OUTPUT/libSDL3-64.so.0"
    SDL32_VERSIONED="$BUILD_OUTPUT/libSDL3-32.so.0"
else
    # ── Native SDL build ──────────────────────────────────────────────────────
    SDL_BUILD64="$SDL_SRC/build-steam64"
    if [[ ! -f "$SDL_BUILD64/libSDL3.so.0" ]]; then
        info "Configuring and building 64-bit SDL"
        cmake -S "$SDL_SRC" -B "$SDL_BUILD64" "${SDL_CMAKE_COMMON[@]}" \
            > /tmp/sdl-cmake64.log 2>&1 \
            || { err "cmake 64-bit failed — see /tmp/sdl-cmake64.log"; exit 1; }
        cmake --build "$SDL_BUILD64" -j"$(nproc)" \
            > /tmp/sdl-build64.log 2>&1 \
            || { err "build 64-bit failed — see /tmp/sdl-build64.log"; exit 1; }
    fi

    SDL_BUILD32="$SDL_SRC/build-steam32"
    install_x11_32
    if [[ ! -f "$SDL_BUILD32/libSDL3.so.0" ]]; then
        info "Configuring and building 32-bit SDL"
        CMAKE_32_EXTRA=(
            "-DCMAKE_C_FLAGS=-m32"
            "-DCMAKE_CXX_FLAGS=-m32"
            "-DCMAKE_EXE_LINKER_FLAGS=-m32"
            "-DCMAKE_SHARED_LINKER_FLAGS=-m32"
        )
        if [[ -n "$X11_32_LIB" && -f "$X11_32_LIB" ]]; then
            CMAKE_32_EXTRA+=("-DX11_LIB=$X11_32_LIB" "-DX11_X11_LIB=$X11_32_LIB")
        fi
        if [[ -n "$X11_INCLUDE" ]]; then
            CMAKE_32_EXTRA+=("-DX11_INCLUDEDIR=$X11_INCLUDE")
        fi
        PKG_CONFIG_CMD=()
        if [[ -n "$PKG_CONFIG_32" && -d "$PKG_CONFIG_32" ]]; then
            PKG_CONFIG_CMD=(env "PKG_CONFIG_LIBDIR=$PKG_CONFIG_32")
        fi
        "${PKG_CONFIG_CMD[@]}" cmake -S "$SDL_SRC" -B "$SDL_BUILD32" \
            "${SDL_CMAKE_COMMON[@]}" "${CMAKE_32_EXTRA[@]}" \
            > /tmp/sdl-cmake32.log 2>&1 \
            || { err "cmake 32-bit failed — see /tmp/sdl-cmake32.log"; exit 1; }
        cmake --build "$SDL_BUILD32" -j"$(nproc)" \
            > /tmp/sdl-build32.log 2>&1 \
            || { err "build 32-bit failed — see /tmp/sdl-build32.log"; exit 1; }
    fi

    SDL64_VERSIONED="$(_find_sdl_versioned "$SDL_BUILD64")"
    SDL32_VERSIONED="$(_find_sdl_versioned "$SDL_BUILD32")"
    [[ -n "$SDL64_VERSIONED" ]] || { err "64-bit SDL .so not found in $SDL_BUILD64"; exit 1; }
    [[ -n "$SDL32_VERSIONED" ]] || { err "32-bit SDL .so not found in $SDL_BUILD32"; exit 1; }
fi

_verify_sdl "$SDL64_VERSIONED" 64
_verify_sdl "$SDL32_VERSIONED" 32

# ── 5. Deploy patched SDL ─────────────────────────────────────────────────────
info "Deploying patched SDL to $SDL_DEPLOY_DIR"
mkdir -p "$SDL_DEPLOY_DIR"

install -m 755 "$SDL64_VERSIONED" "$SDL_DEPLOY_DIR/libSDL3-64.so.0"
install -m 755 "$SDL32_VERSIONED" "$SDL_DEPLOY_DIR/libSDL3-32.so.0"

strip --strip-unneeded "$SDL_DEPLOY_DIR/libSDL3-64.so.0" 2>/dev/null || true
strip --strip-unneeded "$SDL_DEPLOY_DIR/libSDL3-32.so.0" 2>/dev/null || true

ok "SDL deployed"

# ── 5b. SDL_TryLockJoysticks shim ─────────────────────────────────────────────
# Steam's `steamui.so` requires `SDL_TryLockJoysticks@@SDL3_0.0.0`, a symbol
# Valve's internal SDL fork exports but upstream SDL 3.4.4 does not. Without
# it, dlmopen of steamui.so fails before the client UI ever appears.
#
if [[ "$BUILD_MODE" == "sniper" ]]; then
    install -m 755 "$BUILD_OUTPUT/sdl3_shim64.so" "$SDL_DEPLOY_DIR/sdl3_shim64.so"
    install -m 755 "$BUILD_OUTPUT/sdl3_shim32.so" "$SDL_DEPLOY_DIR/sdl3_shim32.so"
else
    info "Building SDL_TryLockJoysticks shims"
    for _arch in 64 32; do
        gcc -shared -fPIC -m"$_arch" \
            -Wl,--version-script="$REPO_ROOT/scripts/sdl3_shim.map" \
            -Wl,-soname,sdl3_shim.so \
            -Wl,-rpath,'$ORIGIN' \
            -o "$SDL_DEPLOY_DIR/sdl3_shim${_arch}.so" \
            "$REPO_ROOT/scripts/sdl3_shim.c" \
            -L"$SDL_DEPLOY_DIR" -l:libSDL3-"$_arch".so.0 \
            || { err "$_arch-bit shim build failed"; exit 1; }
    done

    for _arch in 32 64; do
        _lib="$SDL_DEPLOY_DIR/libSDL3-${_arch}.so.0"
        if ! patchelf --print-needed "$_lib" 2>/dev/null | grep -qx 'sdl3_shim.so'; then
            patchelf --add-needed sdl3_shim.so "$_lib" \
                || { err "patchelf failed on $_lib"; exit 1; }
        fi
    done
fi

_verify_shim_dependency "$SDL_DEPLOY_DIR/libSDL3-64.so.0"
_verify_shim_dependency "$SDL_DEPLOY_DIR/libSDL3-32.so.0"

ok "SDL_TryLockJoysticks shim built and wired"

# ── 6. Deploy SDL ────────────────────────────────────────────────────────────
deploy_direct
remove_wrapper_wiring

if [[ -n "$BUILD_OUTPUT" ]]; then
    rm -rf "$BUILD_OUTPUT"
    BUILD_OUTPUT=""
fi

# ── 8. Udev rule ──────────────────────────────────────────────────────────────
info "Installing udev rule"

OLD_PADCTL_RULE="/etc/udev/rules.d/60-padctl-vader5-userspace.rules"
if [[ -f "$OLD_PADCTL_RULE" ]]; then
    info "Disabling old padctl udev rule"
    sudo mv "$OLD_PADCTL_RULE" "${OLD_PADCTL_RULE}.disabled" \
        || warn "Could not disable old padctl rule — remove it manually if present"
fi

sudo install -m 644 "$UDEV_RULE_SRC" "$UDEV_RULE_DST"
sudo install -m 755 "$XPAD_SCRIPT_SRC" "$XPAD_SCRIPT_DST"
sudo install -m 644 "$XPAD_SERVICE_SRC" "$XPAD_SERVICE_DST"
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo systemctl daemon-reload
sudo systemctl enable --now vader5-xpad-unbind.service
ok "Udev rule and boot-time xpad unbind service installed"

# ── 9. Restart Steam ──────────────────────────────────────────────────────────
if [[ "$WIRE_MODE" == "service" ]] \
        && systemctl --user is-active steam-launcher.service &>/dev/null; then
    info "Restarting steam-launcher.service"
    systemctl --user restart steam-launcher.service
    ok "Steam restarted"
elif [[ "$WIRE_MODE" == "service" ]]; then
    warn "steam-launcher.service is not running — start Steam to load the patched libraries"
else
    warn "Close and reopen Steam from your app menu to load the patched libraries"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
ok "Installation complete."
echo ""
echo "  Patched SDL:  $SDL_DEPLOY_DIR/"
echo "  Steam SDL:    $STEAM_ROOT/ubuntu12_{32,64}/"
echo "  Backups:      $DIRECT_BACKUP_DIR/"
echo "  Udev rule:    $UDEV_RULE_DST"
echo ""
echo "Next steps:"
echo "  1. Replug the Vader 5 Pro (or reconnect the 2.4G dongle) so the new"
echo "     udev rule fires and unbinds xpad from interface 0."
echo "  2. In Steam: Settings → Controller → Detected Controllers."
echo "     The device should now appear as 'Flydigi Vader 5 Pro' (or similar)"
echo "     rather than 'Generic X-Box pad'."
echo "  3. If it still shows as Xbox, check the logs:"
echo "     journalctl --user -u steam-launcher.service -n 50  (service mode)"
echo "     grep -n 'Flydigi\|Vader\|HIDAPI' ~/.local/share/Steam/logs/controller.txt"
