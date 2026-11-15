#!/bin/sh
# ==============================================================================
# Jio AirFiber JIDU6401 Tri-Color Status LED Monitor
# Controls /sys/class/leds/{red,green,blue}:status based on real-time WAN state
# 🟢 Green:       Dual-stack online (464XLAT IPv4 + native IPv6 active)
# 🔵 Blue:        Native IPv6 active, 464XLAT CLAT connecting
# 🔴 Red:         WAN interface down / no upstream default route
# ==============================================================================

LED_RED="/sys/class/leds/red:status"
LED_GREEN="/sys/class/leds/green:status"
LED_BLUE="/sys/class/leds/blue:status"

set_led() {
    local r="$1" g="$2" b="$3"
    [ -d "$LED_RED" ] && echo "$r" > "$LED_RED/brightness" 2>/dev/null || true
    [ -d "$LED_GREEN" ] && echo "$g" > "$LED_GREEN/brightness" 2>/dev/null || true
    [ -d "$LED_BLUE" ] && echo "$b" > "$LED_BLUE/brightness" 2>/dev/null || true
}

echo "[*] Starting Jio AirFiber JIDU6401 LED status daemon..."

while true; do
    # 1. Check if 464-clat has IPv4 default route
    HAS_IPV4=0
    if ip route show default 2>/dev/null | grep -qE "464-clat|464-wan"; then
        HAS_IPV4=1
    fi

    # 2. Check if IPv6 default route exists on wan.1015
    HAS_IPV6=0
    if ip -6 route show default 2>/dev/null | grep -qE "wan"; then
        HAS_IPV6=1
    fi

    if [ "$HAS_IPV4" -eq 1 ] && [ "$HAS_IPV6" -eq 1 ]; then
        # 🟢 Solid Green: Full Dual-Stack Operational
        set_led 0 1 0
    elif [ "$HAS_IPV6" -eq 1 ]; then
        # 🔵 Solid Blue: IPv6 connected, CLAT pending
        set_led 0 0 1
    else
        # 🔴 Solid Red: No WAN route
        set_led 1 0 0
    fi

    sleep 5
done
