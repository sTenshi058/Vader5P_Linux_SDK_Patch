# Flydigi Vader 5 Pro — native SDL HIDAPI on Linux, direct deploy edition!

This is a fork of the Vader 5 Pro Linux fix by @DuncanTPerkins, modified to add the suggested changes by @firefloc in the issue, with a few modifications of my own.

Why? It's been months since the last update of the original project, and the suggested fixes in the issue weren't made into a PR either.

I love using the Vader 5P, but the brwap method was triggering me everytime Steam said "failed to apply update, reverting changes", or having to unplug the controller / dongle because the udev rule would sometimes fail to unbind Xpad, and I don't want other people, specially those who have recently made the scary jump to Linux, to face confusion, or similar frustration.

This fork had some AI assistance for debugging purposes, as this took me some trial and error. I'm unsure if the original had any AI usage, but I don't think so.

Below I'll list the main details of this implementation, for more details on the innerworkings, please look at the original godsend of a project.

## Install / Uninstall

```sh
bash scripts/install.sh
```

This installer is intended for controllers already updated to firmware **0x7141 or newer** in the Flydigi Space Station 4. The new Web Station 5 kind of sucks at the moment.

The installer clones SDL3, applies the patch, builds both architectures in the Steam Runtime **Sniper SDK** using Podman, and directly replaces Steam's bundled SDL libraries. To use the native host build instead use:

```sh
bash scripts/install.sh --build native
```

Make sure to close Steam completely before installation.

The script makes a backup the original SDL libraries on `~/.local/share/vader5-driver/steam-backup/`, installs the patched libraries and shims, and pads each SDL file to the stock size detected on the device. Steam updates may replace the patched files, so just run the installer agaian in case it breaks.

Close Steam before uninstalling; `bash scripts/uninstall.sh` restores the saved libraries and retains the backups.

Direct replacement is the only deployment mode, since bwrap method was proving to be a bit funky in reliability. Parameter`--build` accepts `sniper` or `native`, and equivalent build settings are available via `VADER5_BUILD_MODE` and `SNIPER_SDK_IMAGE`.

After installation, replug the controller.

To test: Steam -> Settings -> Controller -> Detected Controllers: the device WILL still appear as a Generic Xbox gamepad, while the Steam logs show that it indeed knows that this controller is a "Flydigi Vader 5 Pro" it seems that because of way the Steam Input configurations work, or maybe something else on Steam's end, however, the full button set and rumble should be working.

To uninstall: `bash scripts/uninstall.sh`

## Compatibility

Works on SteamOS / Steam Deck, Bazzite, Arch, CachyOS, Fedora, Ubuntu, Debian, and any distro running native Steam, flatpak doesn't work, and the systemd unit that executes the script on launch, well, it won't work if you are not on systemd. Users of systemd alternatives can suggest changes of course, or if you have any other way to make a bash script execute on boot

The installer detects package managers for native build dependencies. It does not replace or wrap the Steam launcher.

Package manager (pacman / dnf / apt / zypper) and 32-bit library paths for the optional native build are detected automatically. Missing build tools are offered for auto-install.

### Direct SDL replacement

The upstream fix is not in the SDL build Steam currently ships on Linux, so this repo pins SDL `release-3.4.4` and applies the missing Linux-side Vader 5 Pro patch locally.

The installer replaces `libSDL3.so.0` in Steam's `ubuntu12_32` and `ubuntu12_64` directories, placing each shim alongside its library. Original libraries and shim state are backed up for uninstall. Steam updates may overwrite the replacements, rerun the installer after an update if necessary.

The installer builds a tiny shim (`sdl3_shim{32,64}.so`) that implements `SDL_TryLockJoysticks` by calling `SDL_LockJoysticks` (which exists in upstream SDL) and returning `1`. `patchelf --add-needed sdl3_shim.so` wires it into the patched libraries, and the shims are installed next to Steam's SDL files so `RUNPATH=$ORIGIN` finds them.

This repo is licensed under MIT. The included patch targets SDL, which is licensed upstream under zlib. If you redistribute patched SDL builds, preserve SDL's upstream notices as required by that project.

### xpad unbind

Without the udev rule, `xpad` binds to interface 0 and Steam sees two controllers: a generic Xbox pad alongside the Flydigi HIDAPI device. `60-vader5-sdl.rules` grants `hidraw` access and invokes a retry helper to unbind xpad from interface 0. A boot-time systemd oneshot repeats the scan to cover the cold-boot race.

## File layout

```
~/sdl-build/SDL-3.4.4/                   # pinned SDL source
~/sdl-build/SDL-3.4.4/build-steam32/     # native mode's 32-bit build
~/sdl-build/SDL-3.4.4/build-steam64/     # native mode's 64-bit build

~/.local/share/vader5-driver/sdl/libSDL3-32.so.0   # deployed 32-bit SDL
~/.local/share/vader5-driver/sdl/libSDL3-64.so.0   # deployed 64-bit SDL
~/.local/share/vader5-driver/sdl/sdl3_shim32.so    # SDL_TryLockJoysticks shim (32-bit)
~/.local/share/vader5-driver/sdl/sdl3_shim64.so    # SDL_TryLockJoysticks shim (64-bit)
~/.local/share/vader5-driver/steam-backup/         # original Steam SDL and shim backups

~/.local/share/Steam/ubuntu12_32/libSDL3.so.0
~/.local/share/Steam/ubuntu12_64/libSDL3.so.0

/etc/udev/rules.d/60-vader5-sdl.rules
/etc/vader5-xpad-unbind.sh
/etc/systemd/system/vader5-xpad-unbind.service
```

The installer directly replaces Steam's SDL files and saves the originals in the backup directory for restoration by the uninstaller.

## Pre-flight

The default Sniper SDK build requires Podman; SDL build dependencies are installed inside the SDK container, so host 32-bit SDL development libraries are not needed. The optional native build also needs CMake, Ninja, GCC multilib, and 32-bit X11 development libraries.

**Arch / SteamOS / CachyOS:**
```sh
sudo pacman -S --needed podman
```

**Fedora / Bazzite / Nobara:**
```sh
sudo dnf install -y podman
```

**Ubuntu / Debian:**
```sh
sudo apt-get install -y podman
```

On SteamOS, run `passwd` first if you haven't set a sudo password.

## Survives updates?

The patched SDL and backups live in `~/.local/share/vader5-driver/`. Steam may overwrite its SDL files during updates; rerun the installer afterward if that happens. The udev rule lives in `/etc/udev/rules.d/`, which is overlayfs-backed on SteamOS.

If Steam ships an SDL update that includes the fix natively, re-run the install script (it's idempotent) to rebuild and verify.

**Is there any realistic VAC risk?**

Probably not.

- VAC targets game processes, memory tampering, hooks, and cheat signatures inside games.
- This project does not inject into game processes, preload into games, or modify game files.
- The installer replaces only Steam's client SDL libraries; it does not modify game files or inject into game processes.

## Troubleshooting

**Controller still shows as Generic X-Box pad after install:**

This is the normal expected behavior due to something else in the Steam backend, logs do reveal the product is correctly identified as a "Flydigi Vader 5 Pro". Test if rumble and the full suite of buttons are available.

**Build fails at 32-bit cmake:**

```sh
ls /usr/lib32/pkgconfig/ | grep -E '^x11|xext'
sudo pacman -S --needed lib32-libx11 lib32-libxext   # Arch/SteamOS
# or: sudo apt-get install -y libx11-dev:i386 libxext-dev:i386   # Ubuntu
```

**SDL patch doesn't apply:**

The patch targets SDL `release-3.4.4`. If you point the installer at a different SDL tree and the file layout has changed, apply the patch manually. If `SDL_HIDAPI_Flydigi_UsesUnnumbered32ByteReports` already exists in the source, this specific patch is no longer needed.
