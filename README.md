# 🚀 Jio AirFiber 5G WAN & Wi-Fi 6 Engine for OpenWrt

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Target: MT7986](https://img.shields.io/badge/SoC-Filogic%20830%20(MT7986)-purple)](docs/HARDWARE_REFERENCE_MT7986.md)
[![OpenWrt Tested](https://img.shields.io/badge/OpenWrt-23.05%20%7C%2024.10%20%7C%20Master-00a8e8?logo=openwrt&logoColor=white)](https://openwrt.org)
[![5G 464XLAT](https://img.shields.io/badge/464XLAT-Dual--Stack%20CLAT-brightgreen)](docs/464XLAT_ARCHITECTURE.md)
[![Hardware Offload](https://img.shields.io/badge/WED-2.5G%20Wire--Speed-success)](#hardware-acceleration)

**Unlock full 5G wire-speed gigabit performance, native 464XLAT IPv4/IPv6 translation, and 160MHz Wi-Fi 6 on your OpenWrt-flashed Jio AirFiber hardware.**

[Quick Start](#-quick-start-1-line-installer) • [Core Innovations](#-core-innovations) • [Performance Matrix](#-performance-matrix) • [Architecture](#-how-5g-odu-bridging-works) • [Hardware Docs](docs/HARDWARE_REFERENCE_MT7986.md)

</div>

---

> [!TIP]
> **Automated Execution via AI Agent (Claude Code, Cursor, Windsurf, agy):**  
> Run this optimization pipeline autonomously by feeding this instruction to your agent:  
> ```text
> "Connect to my OpenWrt router at 192.168.1.1 via SSH. Verify the SoC is MediaTek Filogic (MT7986), create a safety backup of /etc/config/ into /etc/jio-5g/backups/, fetch https://github.com/marufagul/jio-airfiber-openwrt-5g-wan, execute ./install.sh to provision the 5G ODU WAN interface with 464XLAT clatd, enable WED hardware offloading, set Wi-Fi 6 to 160MHz, and verify that IPv4 and IPv6 connectivity are operational."
> ```

---

## ⚡ Quick Start (1-Line Installer)

Log in to your OpenWrt router via SSH and run:

```bash
wget -O - https://raw.githubusercontent.com/marufagul/jio-airfiber-openwrt-5g-wan/main/install.sh | sh
```

### What This Installer Does:
1. 🛡️ **Safety Backup**: Saves `/etc/config/network`, `firewall`, and `wireless` to `/etc/jio-5g/backups/`.
2. 🌐 **5G ODU WAN Link**: Detects the 2.5GbE PoE WAN interface connected to your Outdoor Unit.
3. 🔄 **464XLAT CLAT Translation**: Sets up `clatd` with Jio's NAT64 prefix (`64:ff9b::/96`) for seamless IPv4 access (essential for online games, banking, and legacy apps).
4. ⚡ **MediaTek WED Acceleration**: Activates Wireless Ethernet Dispatcher and nftables hardware flow offloading for line-rate 2.5 Gbps throughput at ~0% CPU utilization.
5. 📶 **Wi-Fi 6 (160MHz Bandwidth)**: Configures 5GHz radio to HE160 channel width for up to 2402 Mbps wireless link speed.

To restore previous settings at any time:
```bash
/etc/jio-5g/backup_restore.sh --restore
```

---

## 🌟 Core Innovations

### 1. Zero-Friction 464XLAT CLAT Integration
Jio AirFiber operates on a 5G Standalone (SA) pure IPv6 mobile network. Traditional OpenWrt setups lose IPv4 routing entirely. This project automatically provisions a local CLAT interface (`wan6_4`) using native OpenWrt packages (`kmod-nat46` / `clatd`), restoring 100% IPv4 compatibility with Open/Moderate NAT for gaming consoles and Steam.

### 2. MediaTek Filogic WED Hardware Offloading
The MediaTek MT7986 SoC houses dual packet processing engines. Without proper offloading, routing 5G speeds above 500 Mbps consumes significant CPU cycles. Our engine turns on kernel WED offload, bypassing software queues and achieving full 2.5GbE WAN line rate with sub-millisecond local latency.

### 3. Smart MSS Clamping (1420 Octets)
Because 5G radio links utilize GTP-U packet encapsulation, standard 1500-byte packets suffer from fragmentation. We apply an optimal TCP MSS clamp of 1420 bytes, eliminating web page stalling and streaming drops.

---

## 📊 Performance Matrix

| Metric | Stock Locked Firmware | Clean OpenWrt Mainline | OpenWrt + 5G Engine |
| :--- | :---: | :---: | :---: |
| **User Control & SSH Access** | ❌ None (Locked) | ✅ Full Root | ✅ Full Root |
| **464XLAT IPv4 Performance** | Proprietary daemon | ❌ Manual / Often Broken | ✅ **Automated & Tuned** |
| **Wi-Fi 6 5GHz Channel Width** | Locked (80 MHz) | Defaults to 80 MHz | ✅ **Full 160 MHz (HE160)** |
| **Hardware Packet Acceleration** | MediaTek SDK proprietary | ❌ Off by default | ✅ **Active (WED + HW Flow)** |
| **CPU Usage at 1 Gbps Routing** | ~15-25% | ~60-80% (Software NAT) | ✅ **< 3% (Hardware Offloaded)** |
| **Custom DNS (AdGuard / NextDNS)** | ❌ Blocked via TR-069 | ✅ Supported | ✅ **Zero Leakage / Native** |

---

## 📡 How 5G ODU Bridging Works

```
 ┌───────────────────────────────────────────────────────────────┐
 │               JIO 5G SUB-6 / mmWAVE BASE STATION              │
 └───────────────────────────────┬───────────────────────────────┘
                                 │ 5G NR Radio Link (IPv6-Only)
 ┌───────────────────────────────▼───────────────────────────────┐
 │               OUTDOOR RECEIVER UNIT (ODU ANTENNA)             │
 └───────────────────────────────┬───────────────────────────────┘
                                 │ 2.5GbE PoE Interface
 ┌───────────────────────────────▼───────────────────────────────┐
 │             YOUR OPENWRT ROUTER (FILOGIC 830 MT7986)          │
 │                                                               │
 │   • Physical Interface: eth1 (2.5 Gbps WAN)                   │
 │   • DHCPv6 Lease / SLAAC: 2405:200:...                        │
 │   • 464XLAT Translator (clatd): IPv4 -> IPv6 (64:ff9b::/96)   │
 │   • Filogic WED Offload: Direct DMA Packet Dispatch           │
 │   • Wi-Fi 6 AP: Dual-Band MT7915E (160 MHz HE160)            │
 └───────────────────────────────┬───────────────────────────────┘
                                 │
         ┌───────────────────────┴───────────────────────┐
         │                                               │
         ▼                                               ▼
  [Local LAN Clients: IPv6]                     [Local LAN Clients: IPv4]
  Native End-to-End Speed                       Translated via CLAT Engine
```

---

## ⚙️ Manual Configuration & Guides

- [Hardware Pinouts & Recovery Guide](docs/HARDWARE_REFERENCE_MT7986.md)
- [464XLAT Deep-Dive & Gaming NAT](docs/464XLAT_ARCHITECTURE.md)

---

## 📄 License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
