#!/usr/bin/env bash
# Build patched 32/64-bit SDL3 + SDL_TryLockJoysticks shims inside the
# Steam Runtime "sniper" SDK. Produces libs that only need GLIBC ≤ 2.29, so they load against Steam's host libc the same way stock libSDL3 does


# Expected mounts (see install.sh):
# /src/SDL   SDL source (already patched) as read-only
# /src/repo  this repository
# /out       deploy directory for the finished .so files

# Build trees live in /tmp inside the container. Never reuse $SDL_SRC/build-steam{32,64} since those are often leftover
# native host compiles that need GLIBC_2.38+

set -euo pipefail

SDL_SRC="${SDL_SRC:-/src/SDL}"
REPO_ROOT="${REPO_ROOT:-/src/repo}"
OUT_DIR="${OUT_DIR:-/out}"

# shellcheck source=sdl-cmake-common.sh
source "$REPO_ROOT/scripts/sdl-cmake-common.sh"

export DEBIAN_FRONTEND=noninteractive

echo "compiler: $(gcc -dumpmachine) $(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)"
echo "libc: $(ldd --version 2>&1 | head -1)"

dpkg --add-architecture i386
apt-get update -qq
apt-get install -y --no-install-recommends \
    cmake ninja-build git patch patchelf pkg-config binutils \
    gcc g++ gcc-multilib g++-multilib \
    libx11-dev libxext-dev \
    libx11-dev:i386 libxext-dev:i386 \
    libxcursor-dev:i386 libxi-dev:i386 libxfixes-dev:i386 \
    libxrandr-dev:i386 libxrender-dev:i386 libxinerama-dev:i386 \
    libxss-dev:i386 libxtst-dev:i386

mkdir -p "$OUT_DIR"
# Drop any host-built artifacts that were sitting in /out from a previous run.
rm -f "$OUT_DIR"/libSDL3-*.so.0 "$OUT_DIR"/sdl3_shim*.so

SDL_BUILD64="/tmp/sdl-build-sniper64"
SDL_BUILD32="/tmp/sdl-build-sniper32"

cmake -S "$SDL_SRC" -B "$SDL_BUILD64" "${SDL_CMAKE_COMMON[@]}"
cmake --build "$SDL_BUILD64" -j"$(nproc)"

PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig \
cmake -S "$SDL_SRC" -B "$SDL_BUILD32" \
    "${SDL_CMAKE_COMMON[@]}" \
    -DCMAKE_C_FLAGS=-m32 \
    -DCMAKE_CXX_FLAGS=-m32 \
    -DCMAKE_EXE_LINKER_FLAGS=-m32 \
    -DCMAKE_SHARED_LINKER_FLAGS=-m32
cmake --build "$SDL_BUILD32" -j"$(nproc)"

find_versioned() {
    find "$1" -maxdepth 1 -name 'libSDL3.so.0.*' | head -1
}

SDL64="$(find_versioned "$SDL_BUILD64")"
SDL32="$(find_versioned "$SDL_BUILD32")"
[[ -n "$SDL64" && -n "$SDL32" ]] || { echo "SDL .so not found" >&2; exit 1; }

install -m 755 "$SDL64" "$OUT_DIR/libSDL3-64.so.0"
install -m 755 "$SDL32" "$OUT_DIR/libSDL3-32.so.0"
strip --strip-unneeded "$OUT_DIR/libSDL3-64.so.0" "$OUT_DIR/libSDL3-32.so.0"

# shims 
gcc -shared -fPIC -m64 \
    -Wl,--version-script="$REPO_ROOT/scripts/sdl3_shim.map" \
    -Wl,-soname,sdl3_shim.so \
    -o "$OUT_DIR/sdl3_shim64.so" "$REPO_ROOT/scripts/sdl3_shim.c" \
    -L"$OUT_DIR" -Wl,-rpath,"\$ORIGIN" -l:libSDL3-64.so.0

gcc -shared -fPIC -m32 \
    -Wl,--version-script="$REPO_ROOT/scripts/sdl3_shim.map" \
    -Wl,-soname,sdl3_shim.so \
    -o "$OUT_DIR/sdl3_shim32.so" "$REPO_ROOT/scripts/sdl3_shim.c" \
    -L"$OUT_DIR" -Wl,-rpath,"\$ORIGIN" -l:libSDL3-32.so.0

for arch in 32 64; do
    lib="$OUT_DIR/libSDL3-${arch}.so.0"
    if ! patchelf --print-needed "$lib" | grep -qx 'sdl3_shim.so'; then
        patchelf --add-needed sdl3_shim.so "$lib"
    fi
done

max_glibc() {
    # Tiny shims often have no versioned GLIBC_* symbols. grep then exits 1,
    # and with pipefail that aborted the whole sniper build after SDL succeeded.
    objdump -T "$1" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' \
        | sort -t. -k1.7,1n -k2,2n -k3,3n | tail -1 || true
}

for f in \
    "$OUT_DIR/libSDL3-64.so.0" "$OUT_DIR/libSDL3-32.so.0" \
    "$OUT_DIR/sdl3_shim64.so" "$OUT_DIR/sdl3_shim32.so"; do
    g="$(max_glibc "$f")"
    echo "glibc requirement $f: ${g:-none}"
    case "${g:-}" in
        GLIBC_2.3[0-9]*|GLIBC_2.[4-9]*|GLIBC_[3-9]*)
            echo "error: $f requires $g (expected ≤ GLIBC_2.29 from sniper SDK)" >&2
            echo "this binary was not produced by the SDK compiler; refusing to install" >&2
            exit 1
            ;;
    esac
done

echo "sniper SDL build complete → $OUT_DIR"
