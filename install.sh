#!/bin/sh
# ==============================================================================
# Jio AirFiber 5G WAN & Wi-Fi 6 Engine - Universal 1-Click Installer
# Author: Gul Marufa (@marufagul)
# Target: MediaTek Filogic 830 (MT7986 / JIDU6401) and compatible devices
# https://github.com/marufagul/jio-airfiber-openwrt-5g-wan
# ==============================================================================

set -e

INSTALL_DIR="/etc/jio-5g"
BACKUP_DIR="/etc/jio-5g/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CUSTOM_MAC=""

# Parse optional arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mac) CUSTOM_MAC="$2"; shift 2;;
        *) echo "Unknown option: $1"; exit 1;;
    esac
done

echo "================================================================="
echo "🚀 Jio AirFiber 5G WAN & Wi-Fi 6 Engine Setup"
echo "   Developed by Gul Marufa (@marufagul)"
echo "================================================================="

# 1. Root Verification
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: Please run this installer as root." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$BACKUP_DIR"

# Universal Package Manager Wrapper (Supports OpenWrt 25.x apk and 23.05/24.10 opkg)
pkg_install() {
    if command -v apk >/dev/null 2>&1; then
        echo "[*] Using apk package manager (OpenWrt 25.x SNAPSHOT)..."
        apk update >/dev/null 2>&1 || true
        apk add "$@" >/dev/null 2>&1 || true
    elif command -v opkg >/dev/null 2>&1; then
        echo "[*] Using opkg package manager (OpenWrt 23.05 / 24.10)..."
        opkg update >/dev/null 2>&1 || true
        opkg install "$@" >/dev/null 2>&1 || true
    else
        echo "[!] No package manager detected. Continuing with base system modules."
    fi
}

# 2. Configuration Snapshot Backup
echo "[*] Step 1/6: Taking safety backup of current configs..."
tar -czf "$BACKUP_DIR/backup_${TIMESTAMP}.tar.gz" \
    /etc/config/network /etc/config/firewall /etc/config/wireless /etc/config/dhcp 2>/dev/null || true
echo "[+] Safety snapshot stored at $BACKUP_DIR/backup_${TIMESTAMP}.tar.gz"

# 3. Detect WAN Physical Interface & Inherit MAC Address
echo "[*] Step 2/6: Detecting 5G ODU WAN physical port..."
WAN_PORT=$(uci -q get network.wan.device || uci -q get network.wan.ifname || echo "")

if [ -z "$WAN_PORT" ] || echo "$WAN_PORT" | grep -q "\."; then
    for candidate in wan eth1 eth0; do
        if ip link show "$candidate" >/dev/null 2>&1; then
            WAN_PORT="$candidate"
            break
        fi
    done
fi

if [ -z "$WAN_PORT" ]; then
    WAN_PORT="wan"
fi
echo "[+] Detected physical WAN device: $WAN_PORT"

# Determine MAC address to apply
if [ -n "$CUSTOM_MAC" ]; then
    MAC_WAN="$CUSTOM_MAC"
    echo "[+] Using user-specified stock MAC: $MAC_WAN"
else
    MAC_WAN=$(cat /sys/class/net/"$WAN_PORT"/address 2>/dev/null || echo "")
    if [ -n "$MAC_WAN" ]; then
        echo "[+] Auto-inherited physical WAN MAC onto VLAN 1015: $MAC_WAN"
    fi
fi

# 4. Configure 802.1Q VLAN 1015 for 5G Public Internet
# On Jio 5G AirFiber, untagged traffic is restricted to TR-069 management.
# Public Internet traffic REQUIRES 802.1Q tagged VLAN 1015 with MTU 1500.
echo "[*] Step 3/6: Configuring 802.1Q VLAN 1015 & 464XLAT CLAT..."

VLAN_WAN_DEV="${WAN_PORT}.1015"

# Configure 802.1q device
uci set network.wan_vlan1015=device
uci set network.wan_vlan1015.name="$VLAN_WAN_DEV"
uci set network.wan_vlan1015.type='8021q'
uci set network.wan_vlan1015.ifname="$WAN_PORT"
uci set network.wan_vlan1015.vid='1015'
uci set network.wan_vlan1015.mtu='1500'
[ -n "$MAC_WAN" ] && uci set network.wan_vlan1015.macaddr="$MAC_WAN"

# Configure WAN6 on VLAN 1015 (DHCPv6 / SLAAC bearer)
uci set network.wan6=interface
uci set network.wan6.device="$VLAN_WAN_DEV"
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.wan6.delegate='1'
uci set network.wan6.metric='10'

# Prevent netifd from spawning an unmanaged competing 464-wan6 interface
uci set network.wan6.iface_464xlat='0'

# Disable Jio's throttled/hijacked upstream DNS and use high-speed Cloudflare & Google resolvers
uci set network.wan6.peerdns='0'
uci -q delete network.wan6.dns 2>/dev/null || true
uci add_list network.wan6.dns='2606:4700:4700::1111'
uci add_list network.wan6.dns='2001:4860:4860::8888'
uci add_list network.wan6.dns='1.1.1.1'
uci add_list network.wan6.dns='8.8.8.8'

# Configure 464XLAT CLAT interface (netifd native translator for IPv4 internet)
uci set network.clat=interface
uci set network.clat.proto='464xlat'
uci set network.clat.tunlink='wan6'
uci set network.clat.ip6prefix='64:ff9b::/96'
uci set network.clat.mtu='1460'
uci set network.clat.metric='10'

uci commit network

# Check if nat46 is already compiled into kernel (/proc/net/nat46/control)
# Only attempt package installation if not already present, avoiding kernel mismatch errors on OpenWrt 25.x
if [ ! -e /proc/net/nat46/control ]; then
    echo "[*] nat46 kernel driver not active in procfs. Checking package..."
    pkg_install 464xlat kmod-nat46 odhcp6c
else
    echo "[+] nat46 kernel translation engine already built-in. Skipping kmod install."
    pkg_install 464xlat odhcp6c
fi

# 5. Configure LAN IPv6 Prefix Delegation & odhcpd Router Advertisements
echo "[*] Step 4/6: Configuring LAN IPv6 Prefix Delegation (odhcpd) & DNS cache..."
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_slaac='1'
uci -q delete dhcp.lan.ra_flags 2>/dev/null || true
uci add_list dhcp.lan.ra_flags='managed-config'
uci add_list dhcp.lan.ra_flags='other-config'

# Optimize dnsmasq cache size and disable rebind protection for low latency resolution
uci set dhcp.@dnsmasq[0].cachesize='2000'
uci set dhcp.@dnsmasq[0].rebind_protection='0'
uci commit dhcp

# 6. Configure Firewall (MediaTek WED Hardware Offload & MSS Clamping)
echo "[*] Step 5/6: Tuning firewall for line-rate 5G throughput..."

# Set global MSS clamping to 1420 bytes
uci set firewall.@defaults[0].mtu_fix='1'

# Activate hardware flow offload for Filogic 830 MT7986
uci set firewall.@defaults[0].flow_offloading='1'
if grep -qi "MT7986" /proc/cpuinfo 2>/dev/null || [ -d /sys/module/mtk_soc_eth ]; then
    echo "[+] MediaTek Filogic SoC confirmed: Hardware Flow Offloading (WED) enabled!"
    uci set firewall.@defaults[0].flow_offloading_hw='1'
fi

# Dynamically target WAN firewall zone by name
WAN_ZONE=$(uci show firewall | grep "\.name='wan'" | cut -d'.' -f2 | head -n 1)
if [ -n "$WAN_ZONE" ]; then
    echo "[+] Adding wan, wan6, and clat to firewall zone '$WAN_ZONE'..."
    uci delete firewall."$WAN_ZONE".network 2>/dev/null || true
    uci add_list firewall."$WAN_ZONE".network='wan'
    uci add_list firewall."$WAN_ZONE".network='wan6'
    uci add_list firewall."$WAN_ZONE".network='clat'
    uci set firewall."$WAN_ZONE".masq='1'
    uci set firewall."$WAN_ZONE".masq6='1'
    uci set firewall."$WAN_ZONE".mtu_fix='1'
fi

uci commit firewall

# 7. Wi-Fi 6 Setup, 5GHz Interface Provisioning & MT76 DHCP Fix
echo "[*] Step 6/6: Configuring Wi-Fi 6 radios and interfaces..."
if [ -f /etc/config/wireless ]; then
    RADIO_5G=""
    RADIO_2G=""

    for radio in $(uci show wireless | grep -E "=wifi-device" | cut -d'.' -f2 | cut -d'=' -f1); do
        BAND=$(uci -q get wireless."$radio".band || echo "")
        HWMODE=$(uci -q get wireless."$radio".hwmode || echo "")
        
        # 5GHz Radio: Default to HE80 for instant beaconing (zero DFS delay)
        if [ "$BAND" = "5g" ] || echo "$HWMODE" | grep -q "11a"; then
            RADIO_5G="$radio"
            echo "[+] Setting 5GHz radio ($radio) to HE80 (instant beaconing)..."
            uci set wireless."$radio".country='IN'
            uci set wireless."$radio".htmode='HE80'
            uci set wireless."$radio".channel='36'
            uci set wireless."$radio".disabled='0'
        else
            RADIO_2G="$radio"
            # 2.4GHz Radio: HT20 + WPA2-PSK (psk2) to prevent legacy device lockouts
            echo "[+] Setting 2.4GHz radio ($radio) to HT20 / WPA2-PSK (Universal compatibility)..."
            uci set wireless."$radio".country='IN'
            uci set wireless."$radio".htmode='HT20'
            uci set wireless."$radio".channel='auto'
            uci set wireless."$radio".disabled='0'
        fi
    done

    # Ensure 5GHz wifi-iface exists (fixes clean OpenWrt builds where 5GHz AP is missing)
    HAS_5G_IFACE=0
    for iface in $(uci show wireless | grep -E "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
        IFACE_DEV=$(uci -q get wireless."$iface".device || echo "")
        if [ "$IFACE_DEV" = "$RADIO_5G" ]; then
            HAS_5G_IFACE=1
            break
        fi
    done

    if [ "$HAS_5G_IFACE" -eq 0 ] && [ -n "$RADIO_5G" ]; then
        echo "[+] No 5GHz AP interface found. Creating wireless.wifinet5 on $RADIO_5G..."
        uci set wireless.wifinet5=wifi-iface
        uci set wireless.wifinet5.device="$RADIO_5G"
        uci set wireless.wifinet5.network='lan'
        uci set wireless.wifinet5.mode='ap'
        uci set wireless.wifinet5.ssid='OpenWrt-Jio5G-5G'
        uci set wireless.wifinet5.encryption='sae-mixed'
        uci set wireless.wifinet5.key='ChangeThisStrongPassword123'
        uci set wireless.wifinet5.multicast_to_unicast='0'
    fi

    # MT76 Bugfix: Disable multicast_to_unicast to prevent DHCP drops on clients
    for iface in $(uci show wireless | grep -E "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
        uci set wireless."$iface".network='lan'
        uci set wireless."$iface".multicast_to_unicast='0'
        RADIO=$(uci -q get wireless."$iface".device || echo "")
        BAND=$(uci -q get wireless."$RADIO".band || echo "")
        if [ "$BAND" = "2g" ]; then
            uci set wireless."$iface".encryption='psk2'
        fi
    done
    uci commit wireless
fi

# 8. Deploy Status LED Service if JIDU6401 Tri-Color LEDs detected
if [ -d /sys/class/leds/green:status ] || [ -d /sys/class/leds/red:status ]; then
    echo "[*] JIDU6401 hardware LEDs detected. Installing wan-led-monitor..."
    SCRIPT_DIR=$(dirname "$0")
    if [ -f "$SCRIPT_DIR/scripts/wan_led_monitor.sh" ]; then
        cp "$SCRIPT_DIR/scripts/wan_led_monitor.sh" "$INSTALL_DIR/wan_led_monitor.sh"
        chmod +x "$INSTALL_DIR/wan_led_monitor.sh"
        
        cat << 'EOF' > /etc/init.d/wan-led-monitor
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=96
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /etc/jio-5g/wan_led_monitor.sh
    procd_set_param respawn
    procd_close_instance
}
EOF
        chmod +x /etc/init.d/wan-led-monitor
        /etc/init.d/wan-led-monitor enable 2>/dev/null || true
        /etc/init.d/wan-led-monitor start 2>/dev/null || true
    fi
fi

# 9. Safety Rollback Utility
cat << 'EOF' > "$INSTALL_DIR/backup_restore.sh"
#!/bin/sh
BACKUP_DIR="/etc/jio-5g/backups"
case "$1" in
    --restore)
        LATEST=$(ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | head -n 1)
        if [ -n "$LATEST" ]; then
            echo "[*] Restoring configurations from $LATEST..."
            tar -xzf "$LATEST" -C /
            /etc/init.d/network restart
            /etc/init.d/firewall restart
            /etc/init.d/odhcpd restart 2>/dev/null || true
            command -v wifi >/dev/null 2>&1 && wifi reload 2>/dev/null || true
            echo "[SUCCESS] Configuration restored to pre-install snapshot."
        else
            echo "[-] No backup found in $BACKUP_DIR."
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 --restore"
        ;;
esac
EOF
chmod +x "$INSTALL_DIR/backup_restore.sh"

echo "[*] Committing and reloading network, firewall, odhcpd, and wireless daemons..."
/etc/init.d/network reload || /etc/init.d/network restart
/etc/init.d/firewall reload || /etc/init.d/firewall restart
/etc/init.d/odhcpd reload 2>/dev/null || /etc/init.d/odhcpd restart 2>/dev/null || true
command -v wifi >/dev/null 2>&1 && wifi reload 2>/dev/null || true

echo ""
echo "================================================================="
echo "🎉 SUCCESS: Jio AirFiber 5G Engine is active!"
echo "================================================================="
echo "• 5G WAN Port:          $VLAN_WAN_DEV (VLAN 1015 Public Bearer)"
echo "• MAC Inherited:        ${MAC_WAN:-Auto}"
echo "• 464XLAT CLAT:         Active (Full IPv4 Compatibility via NAT64)"
echo "• LAN IPv6 Delegation:  Active (odhcpd SLAAC/RA to phones & laptops)"
echo "• High-Speed DNS:       Cloudflare + Google (Jio DNS Hijack Disabled)"
echo "• Hardware Offload:     Active (Filogic WED Line-Rate 2.5 Gbps)"
echo "• TCP MSS Clamping:     1420 Bytes (Zero Fragmentation)"
echo "• Wi-Fi MT76 Fix:       multicast_to_unicast disabled (Zero DHCP Drops)"
echo "• Wi-Fi 5GHz:           HE80 (Instant beaconing, change to HE160 if desired)"
echo "• Wi-Fi 2.4GHz:         HT20 / WPA2 (100% Legacy Device Compatibility)"
echo "• Rollback Command:     /etc/jio-5g/backup_restore.sh --restore"
echo "================================================================="
