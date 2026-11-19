# 🛠️ Manual SSH Configuration Guide: Jio 5G AirFiber on OpenWrt

This guide contains **100% transparent, manual SSH commands** to configure clean OpenWrt on your Jio AirFiber router (Sercomm JIDU6401 / MediaTek Filogic 830 MT7986). 

No AI, no black-box scripts, no installers needed. Every command is explained so you understand exactly what changes in your router.

---

## Prerequisites
1. OpenWrt flashed onto your router.
2. PC connected via Ethernet to **LAN Port 1**.
3. 2.5GbE PoE WAN port connected to the Jio 5G Outdoor Unit (ODU).
4. SSH terminal open:
   ```bash
   ssh root@192.168.1.1
   ```

---

## Step 1: Detect your Physical WAN Interface

Check your physical interface names:
```bash
ip link show
```
On the Sercomm JIDU6401, the 2.5GbE WAN port is typically named `wan` (or `eth1`). Verify which port has carrier when the ODU is plugged in:
```bash
cat /sys/class/net/wan/operstate
```

---

## Step 2: Configure 802.1Q Tagged VLAN 1015

> [!IMPORTANT]
> **Why VLAN 1015 is Required:**  
> On Jio AirFiber 5G, untagged traffic is restricted to TR-069 management. The public 5G Internet bearer is strictly carried on **VLAN ID 1015**.

Run these UCI commands to create the 802.1Q device and inherit your stock MAC address (preventing ODU port flaps):

```bash
# 1. Create VLAN 1015 device
uci set network.wan_vlan1015=device
uci set network.wan_vlan1015.name='wan.1015'
uci set network.wan_vlan1015.type='8021q'
uci set network.wan_vlan1015.ifname='wan'
uci set network.wan_vlan1015.vid='1015'
uci set network.wan_vlan1015.mtu='1500'

# 2. Apply your factory WAN MAC address from bottom sticker (Mandatory for Jio BNG)
uci set network.wan_vlan1015.macaddr='9C:D4:A6:XX:XX:XX'  # <-- Replace with your sticker WAN MAC

# (Optional fallback if sticker is unreadable: inherit physical port address)
# WAN_MAC=$(cat /sys/class/net/wan/address 2>/dev/null)
# [ -n "$WAN_MAC" ] && uci set network.wan_vlan1015.macaddr="$WAN_MAC"

# 3. Configure WAN6 DHCPv6 client on VLAN 1015
uci set network.wan6=interface
uci set network.wan6.device='wan.1015'
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.wan6.delegate='1'
uci set network.wan6.metric='10'
uci set network.wan6.iface_464xlat='0'

# 4. Use high-speed DNS (Disables Jio DNS hijacking)
uci set network.wan6.peerdns='0'
uci -q delete network.wan6.dns
uci add_list network.wan6.dns='2606:4700:4700::1111'
uci add_list network.wan6.dns='2001:4860:4860::8888'
uci add_list network.wan6.dns='1.1.1.1'
uci add_list network.wan6.dns='8.8.8.8'

uci commit network
/etc/init.d/network restart
```

Verify that `wan.1015` receives an IPv6 global address (`2405:201:...`):
```bash
ip -6 addr show dev wan.1015
```

---

## Step 3: Configure 464XLAT CLAT (IPv4 Internet via NAT64)

Jio 5G SA is a pure IPv6 network. To route IPv4 traffic (games, banking, legacy apps), we set up a native 464XLAT translator using Jio's well-known NAT64 prefix (`64:ff9b::/96`):

```bash
# 1. Install CLAT translation support if missing
apk add 464xlat odhcp6c 2>/dev/null || opkg install 464xlat odhcp6c

# 2. Define the CLAT interface in UCI
uci set network.clat=interface
uci set network.clat.proto='464xlat'
uci set network.clat.tunlink='wan6'
uci set network.clat.ip6prefix='64:ff9b::/96'
uci set network.clat.mtu='1460'
uci set network.clat.metric='10'

# 3. Add clat to the WAN firewall zone
WAN_ZONE=$(uci show firewall | grep "\.name='wan'" | cut -d'.' -f2 | head -n 1)
[ -z "$WAN_ZONE" ] && WAN_ZONE="@zone[1]"
uci add_list firewall."$WAN_ZONE".network='clat'
uci set firewall."$WAN_ZONE".masq='1'
uci set firewall."$WAN_ZONE".masq6='1'

uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall restart
```

Verify dual-stack connectivity:
```bash
ping -c 2 1.1.1.1
ping -c 2 2606:4700:4700::1111
```

---

## Step 4: Hardware Offloading (WED) & MSS Clamping

The MediaTek Filogic 830 MT7986 has dual hardware packet processing engines (Wireless Ethernet Dispatcher). Enable hardware offloading and tune MSS to prevent 5G GTP-U packet fragmentation:

```bash
# 1. Enable MediaTek WED hardware flow offloading
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci set firewall.@defaults[0].mtu_fix='1'

# 2. Add TCP MSS clamping (1420 bytes) to nftables
nft add rule inet fw4 mangle_forward oifname "wan.1015" tcp flags syn tcp option maxseg size set 1420 2>/dev/null

uci commit firewall
/etc/init.d/firewall restart
```

---

## Step 5: Wi-Fi 6 Tuning & MT76 DHCP Bugfix

Prevent MT76 broadcast frame drops on dual-band Wi-Fi:

```bash
# 1. Disable multicast_to_unicast on all Wi-Fi interfaces (prevents client DHCP drops)
for iface in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
    uci set wireless."$iface".multicast_to_unicast='0'
done

# 2. Set 5GHz to HE80 or HE160
uci set wireless.radio0.country='IN'
uci set wireless.radio0.htmode='HE80'
uci set wireless.radio0.channel='36'
uci set wireless.radio0.disabled='0'

# 3. Set 2.4GHz to HT20 with WPA2-PSK (Universal IoT device compatibility)
uci set wireless.radio1.country='IN'
uci set wireless.radio1.htmode='HT20'
uci set wireless.radio1.channel='auto'
uci set wireless.radio1.disabled='0'

uci commit wireless
wifi reload
```

---

## Step 6: Diagnostic & Verification Commands

Check everything from your SSH terminal:
```bash
# Check WAN interfaces & IP addresses
ip -br addr show

# Check default routes (IPv4 via CLAT, IPv6 via wan.1015)
ip route show default
ip -6 route show default

# Check hardware flow offload entries
cat /proc/net/nf_conntrack | grep -i "offload" | head -n 10

# Test DNS latency
nslookup google.com 1.1.1.1
```
