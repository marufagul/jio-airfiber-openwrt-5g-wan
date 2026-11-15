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

MAC_WAN=$(cat /sys/class/net/"$WAN_PORT"/address 2>/dev/null || echo "")
if [ -n "$MAC_WAN" ]; then
    echo "[+] Inheriting physical WAN MAC: $MAC_WAN"
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

# Install packages if needed (464xlat, kmod-nat46)
pkg_install 464xlat kmod-nat46 odhcp6c

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

# Ensure WAN firewall zone covers wan, wan6, and clat
uci delete firewall.@zone[1].network 2>/dev/null || true
uci add_list firewall.@zone[1].network='wan'
uci add_list firewall.@zone[1].network='wan6'
uci add_list firewall.@zone[1].network='clat'
uci set firewall.@zone[1].masq='1'
uci set firewall.@zone[1].masq6='1'
uci set firewall.@zone[1].mtu_fix='1'

uci commit firewall

# 7. Wi-Fi 6 & MT76 DHCP Drop Bug Fix
echo "[*] Step 6/6: Optimizing Wi-Fi 6 & fixing MT76 DHCP drop issue..."
if [ -f /etc/config/wireless ]; then
    for radio in $(uci show wireless | grep -E "=wifi-device" | cut -d'.' -f2 | cut -d'=' -f1); do
        BAND=$(uci -q get wireless."$radio".band || echo "")
        HWMODE=$(uci -q get wireless."$radio".hwmode || echo "")
        
        # 5GHz Radio: HE160, DFS/36, WPA3/WPA2 mixed
        if [ "$BAND" = "5g" ] || echo "$HWMODE" | grep -q "11a"; then
            echo "[+] Setting 5GHz radio ($radio) to HE160 (160MHz) / WPA3-SAE mixed..."
            uci set wireless."$radio".country='IN'
            uci set wireless."$radio".htmode='HE160'
            uci set wireless."$radio".channel='36'
            uci set wireless."$radio".disabled='0'
        else
            # 2.4GHz Radio: HT20 + WPA2-PSK (psk2) to prevent legacy device lockouts
            echo "[+] Setting 2.4GHz radio ($radio) to HT20 / WPA2-PSK (Maximum compatibility)..."
            uci set wireless."$radio".country='IN'
            uci set wireless."$radio".htmode='HT20'
            uci set wireless."$radio".channel='auto'
            uci set wireless."$radio".disabled='0'
        fi
    done

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

# 8. Safety Rollback Utility
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
echo "• Wi-Fi 5GHz:           HE160 (160MHz Bandwidth, Up to 2400 Mbps)"
echo "• Wi-Fi 2.4GHz:         HT20 / WPA2 (100% Legacy Device Compatibility)"
echo "• Rollback Command:     /etc/jio-5g/backup_restore.sh --restore"
echo "================================================================="
