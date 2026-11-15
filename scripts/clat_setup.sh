#!/bin/sh
# ==============================================================================
# 464XLAT CLAT Setup & Diagnostics for Reliance Jio 5G SA Network
# Verifies discovery of NAT64 prefix (64:ff9b::/96) and manages local translator
# ==============================================================================

set -e

NAT64_PREFIX="64:ff9b::/96"
IPV4_DUMMY_IP="192.0.0.1"

echo "[*] Initializing 464XLAT CLAT diagnostics..."

# 1. Check if native IPv6 default route exists
IPV6_DEFAULT=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -n 1)
if [ -z "$IPV6_DEFAULT" ]; then
    echo "[-] Error: No IPv6 default gateway found on WAN interface."
    echo "    Make sure the 5G ODU is powered on and connected to the 2.5GbE WAN port."
    exit 1
fi
echo "[+] Detected active 5G IPv6 gateway: $IPV6_DEFAULT"

# 2. Check for NAT64 reachability using Well-Known Prefix (WKP) or DNS64
echo "[*] Testing NAT64 synthesis (ipv4only.arpa query)..."
NAT64_SYNTH=$(nslookup -type=aaaa ipv4only.arpa 2>/dev/null | grep -i "Address" | grep "64:ff9b" | head -n 1 || true)

if [ -n "$NAT64_SYNTH" ]; then
    echo "[+] Jio NAT64 prefix confirmed: $NAT64_SYNTH"
else
    echo "[!] DNS64 query returned empty. Falling back to RFC 6052 Well-Known Prefix: $NAT64_PREFIX"
fi

# 3. Ensure clat interface is initialized
if ip link show 464-wan6 >/dev/null 2>&1; then
    echo "[+] 464-wan6 interface is already active."
else
    echo "[*] Triggering clat daemon reload..."
    command -v clatd >/dev/null 2>&1 && /etc/init.d/clatd restart 2>/dev/null || true
fi

# 4. Verify end-to-end IPv4 connectivity over IPv6 CLAT
echo "[*] Testing end-to-end IPv4 ping through CLAT..."
if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo "[SUCCESS] 464XLAT is working! IPv4 Internet is fully operational over Jio 5G."
else
    echo "[!] Ping to 1.1.1.1 failed. Please check /etc/config/network and clatd status."
fi
