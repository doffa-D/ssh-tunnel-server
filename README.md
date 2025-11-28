# HTTP Custom SSH Tunnel Server

High-performance WebSocket-to-SSH tunnel server optimized for HTTP Custom Android app with carrier throttling bypass features.

## Features

- 🚀 **High-Performance C Proxy** - Native compiled proxy with 1MB buffers
- ⚡ **BBR Congestion Control** - Google's fast TCP algorithm enabled
- 🔧 **TCP Optimized** - Large buffers, MSS clamping, optimized window scaling
- 🔒 **Dropbear SSH** - Lightweight SSH server with 1MB receive window
- 📡 **UDP Support** - BadVPN-UDPGW for gaming/VoIP

## Quick Start

### Server Setup (Ubuntu 20.04/22.04)

```bash
# Download and run setup script
chmod +x server-setup.sh
sudo ./server-setup.sh
```

### Manual Installation

```bash
# 1. Compile the C proxy
gcc -O3 -march=native -o /usr/local/bin/fastproxy fastproxy.c -lpthread

# 2. Install Dropbear SSH
sudo apt install -y dropbear

# 3. Configure Dropbear
sudo tee /etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=109
DROPBEAR_EXTRA_ARGS="-W 1048576 -K 60"
DROPBEAR_BANNER=""
EOF
sudo systemctl restart dropbear

# 4. Create systemd service for proxy
sudo tee /etc/systemd/system/ws-tunnel.service <<EOF
[Unit]
Description=WebSocket to SSH Tunnel Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/fastproxy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable ws-tunnel
sudo systemctl start ws-tunnel
```

## Files

| File | Description |
|------|-------------|
| `server-setup.sh` | Complete auto-installer script |
| `fastproxy.c` | High-performance C proxy source |
| `CLIENT-CONFIG.md` | HTTP Custom app configuration |
| `tcp-optimizations.conf` | System TCP tuning settings |

## Architecture

```
HTTP Custom App (Android)
         │
         ▼ HTTP + WebSocket Headers
┌─────────────────────────┐
│  Port 8880              │
│  fastproxy (C)          │
│  - 1MB buffers          │
│  - TCP_NODELAY          │
│  - Multi-threaded       │
└───────────┬─────────────┘
            │
            ▼ Raw TCP
┌─────────────────────────┐
│  Port 109               │
│  Dropbear SSH           │
│  - 1MB receive window   │
│  - Optimized for speed  │
└───────────┬─────────────┘
            │
            ▼
        Internet
```

## Ports Used

| Port | Service | Protocol |
|------|---------|----------|
| 22 | SSH (management) | TCP |
| 109 | Dropbear SSH (tunnel) | TCP |
| 8880 | FastProxy (HTTP/WebSocket) | TCP |
| 7300 | BadVPN UDPGW | UDP/TCP |

## Performance Optimizations

### Server-Side
- C compiled proxy (native performance)
- 1MB socket buffers (proxy + SSH)
- BBR congestion control enabled
- MSS clamping to prevent fragmentation
- TCP Fast Open enabled
- Dropbear with 1MB receive window

### TCP Settings Applied
```bash
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
```

### Firewall Rules (MSS Clamping)
```bash
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

## HTTP Custom Payload Examples

### WebSocket Upgrade
```
GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

### Split Request (Cloudflare)
```
GET /cdn-cgi/trace HTTP/1.1[crlf]Host: tweetdeck.twitter.com[crlf][crlf]GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]
```

### Minimal (Fastest)
```
GET / HTTP/1.1[crlf]Host: a[crlf][crlf]
```

## Service Management

```bash
# Status
systemctl status ws-tunnel
systemctl status dropbear
systemctl status badvpn-udpgw

# Logs
journalctl -u ws-tunnel -f
journalctl -u dropbear -f

# Restart
systemctl restart ws-tunnel
systemctl restart dropbear

# Check ports
netstat -tulpn | grep -E '8880|109|7300'
```

## Troubleshooting

### Slow Speed (Carrier Throttling)
1. **SNI Spoofing**: Set SNI in HTTP Custom to `speedtest.net` or `google.com`
2. **UDP Tweaks**: Enable UDP tweak with Buffer=64, TX/RX=30
3. **DNS**: Use Cloudflare DNS (1.1.1.1) in HTTP Custom
4. **Payload**: Try different payloads (WebSocket upgrade, split request)
5. Verify BBR is enabled: `sysctl net.ipv4.tcp_congestion_control`

### Connection Issues
1. Check firewall: `ufw status`
2. Verify services: `systemctl status ws-tunnel dropbear`
3. Test port: `nc -zv YOUR_IP 8880`
4. Check Dropbear auth: `journalctl -u dropbear -n 20`

### Service Won't Start
1. Check logs: `journalctl -u ws-tunnel -n 50`
2. Verify binary: `/usr/local/bin/fastproxy`
3. Check port conflict: `netstat -tulpn | grep 8880`
4. Verify Dropbear port: `netstat -tulpn | grep 109`

## Speed Expectations

| Scenario | Expected Speed |
|----------|---------------|
| Direct IP connection | 50-100+ Mbps |
| Through Cloudflare | 10-50 Mbps |
| Mobile carrier throttling | 2-10 Mbps |

**Note:** Final speed depends on mobile carrier, phone CPU, and network conditions.

## License

MIT License - Use at your own risk for educational and research purposes only.





