#!/bin/sh
# Unbinds xpad from Flydigi Vader 5 Pro (USB 37d7:2401) interface 0.

# The udev ACTION=="add" rule often loses to bind fast enough on a cold boot:
# The dongle enumerates, xpad claims interface 0, and Steam sees a generic Xbox pad.

# This script is the boot-time catch-up: walk every USB interface, and if it is the Vader's interface 0 (Xbox interface) bound to xpad,
# unbind it.

# Installed to /etc/vader5-xpad-unbind.sh and run by
# vader5-xpad-unbind.service. Also usable by hand: sudo /etc/vader5-xpad-unbind.sh


unbind_interface() {
    name="$1"
    case "$name" in
        *:*) ;;
        *) return 0 ;;
    esac

    iface="/sys/bus/usb/devices/$name"
    [ -e "$iface/bInterfaceNumber" ] || return 1
    [ "$(cat "$iface/bInterfaceNumber" 2>/dev/null)" = "00" ] || return 0

    parent="${iface%:*}"
    [ -f "$parent/idVendor" ] && [ -f "$parent/idProduct" ] || return 1
    [ "$(cat "$parent/idVendor" 2>/dev/null)" = "37d7" ] || return 0
    [ "$(cat "$parent/idProduct" 2>/dev/null)" = "2401" ] || return 0
    [ -e "/sys/bus/usb/drivers/xpad/$name" ] || return 1
    echo -n "$name" > /sys/bus/usb/drivers/xpad/unbind
}

# Udev passes the interface name. Retry until xpad has claimed it or the
# device has been unplugged; the boot service scans all connected devices.
if [ "$#" -gt 0 ]; then
    i=0
    while [ "$i" -lt 8 ]; do
        if unbind_interface "$1"; then
            exit 0
        fi
        i=$((i + 1))
        sleep 0.3
    done
    exit 0
fi

# Retry: USB + xpad probe can land after this oneshot on cold boot.
i=0
while [ "$i" -lt 8 ]; do
    for iface in /sys/bus/usb/devices/*:*; do
        [ -e "$iface/bInterfaceNumber" ] || continue
        unbind_interface "${iface##*/}" || true
    done
    i=$((i + 1))
    sleep 0.3
done

exit 0
