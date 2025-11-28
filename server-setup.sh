#!/bin/bash

# =============================================================================
# High-Performance WebSocket-to-SSH Tunnel Server Setup
# Compatible with Ubuntu 20.04/22.04
# Optimized for maximum throughput with HTTP Custom / HTTP Injector
# =============================================================================

echo "=========================================="
echo "WebSocket-to-SSH Tunnel Server Setup"
echo "      (High Performance Edition)"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[*]${NC} $1"; }
print_error() { echo -e "${RED}[!]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# =============================================================================
# Step 1: System Update and Package Installation
# =============================================================================
print_status "Updating system packages..."
apt update -qq

print_status "Installing required packages..."
apt install -y openssh-server build-essential cmake git screen ufw net-tools > /dev/null 2>&1

# =============================================================================
# Step 2: Apply TCP Performance Optimizations
# =============================================================================
print_status "Applying TCP performance optimizations..."

cat > /etc/sysctl.d/99-tunnel-performance.conf << 'EOF'
# TCP Performance Tuning for SSH Tunnel
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
EOF

# Enable BBR congestion control
modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-tunnel-performance.conf > /dev/null 2>&1

print_status "TCP optimizations applied (BBR enabled)"

# =============================================================================
# Step 3: Configure OpenSSH for High Performance
# =============================================================================
print_status "Configuring OpenSSH on port 110..."

# Backup original config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s) 2>/dev/null || true

# Add high-performance settings
grep -q "^Port 110" /etc/ssh/sshd_config || cat >> /etc/ssh/sshd_config << 'EOF'

# High Performance SSH Settings for Tunnel
Port 110
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
Compression no
UseDNS no
GSSAPIAuthentication no
MaxStartups 100:30:500
EOF

systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
print_status "OpenSSH configured on port 110"

# =============================================================================
# Step 4: Compile and Install High-Performance C Proxy
# =============================================================================
print_status "Compiling high-performance C proxy..."

cat > /tmp/fastproxy.c << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <signal.h>

#define LISTEN_PORT 8880
#define SSH_PORT 110
#define BUFFER_SIZE 1048576

typedef struct { int client_fd; int ssh_fd; } connection_t;

void optimize_socket(int fd) {
    int opt = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    int bufsize = 1048576;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof(bufsize));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &opt, sizeof(opt));
}

void* pipe_data(void* arg) {
    int* fds = (int*)arg;
    char* buffer = malloc(BUFFER_SIZE);
    while (1) {
        ssize_t n = recv(fds[0], buffer, BUFFER_SIZE, 0);
        if (n <= 0) break;
        ssize_t sent = 0;
        while (sent < n) {
            ssize_t s = send(fds[1], buffer + sent, n - sent, 0);
            if (s <= 0) break;
            sent += s;
        }
        if (sent != n) break;
    }
    shutdown(fds[0], SHUT_RD);
    shutdown(fds[1], SHUT_WR);
    free(buffer);
    free(arg);
    return NULL;
}

void* handle_connection(void* arg) {
    connection_t* conn = (connection_t*)arg;
    char header_buf[16384];
    int header_len = 0;
    
    while (header_len < sizeof(header_buf) - 1) {
        int n = recv(conn->client_fd, header_buf + header_len, 1, 0);
        if (n <= 0) goto cleanup;
        header_len++;
        if (header_len >= 4 && memcmp(header_buf + header_len - 4, "\r\n\r\n", 4) == 0) break;
    }
    
    conn->ssh_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (conn->ssh_fd < 0) goto cleanup;
    optimize_socket(conn->ssh_fd);
    
    struct sockaddr_in ssh_addr = {.sin_family = AF_INET, .sin_port = htons(SSH_PORT)};
    ssh_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    if (connect(conn->ssh_fd, (struct sockaddr*)&ssh_addr, sizeof(ssh_addr)) < 0) {
        close(conn->ssh_fd);
        goto cleanup;
    }
    
    const char* response = (strstr(header_buf, "websocket") || strstr(header_buf, "Upgrade")) ?
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n" :
        "HTTP/1.1 200 Connection Established\r\n\r\n";
    send(conn->client_fd, response, strlen(response), 0);
    
    int* fds1 = malloc(2 * sizeof(int));
    int* fds2 = malloc(2 * sizeof(int));
    fds1[0] = conn->client_fd; fds1[1] = conn->ssh_fd;
    fds2[0] = conn->ssh_fd; fds2[1] = conn->client_fd;
    
    pthread_t t1, t2;
    pthread_create(&t1, NULL, pipe_data, fds1);
    pthread_create(&t2, NULL, pipe_data, fds2);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    
cleanup:
    close(conn->client_fd);
    if (conn->ssh_fd > 0) close(conn->ssh_fd);
    free(conn);
    return NULL;
}

int main() {
    signal(SIGPIPE, SIG_IGN);
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
    optimize_socket(server_fd);
    
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(LISTEN_PORT), .sin_addr.s_addr = INADDR_ANY};
    bind(server_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(server_fd, 4096);
    
    printf("Fast HTTP Proxy on port %d -> SSH port %d\n", LISTEN_PORT, SSH_PORT);
    fflush(stdout);
    
    while (1) {
        struct sockaddr_in client_addr;
        socklen_t len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &len);
        if (client_fd < 0) continue;
        optimize_socket(client_fd);
        
        connection_t* conn = malloc(sizeof(connection_t));
        conn->client_fd = client_fd;
        conn->ssh_fd = -1;
        
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&thread, &attr, handle_connection, conn);
    }
}
CEOF

gcc -O3 -march=native -o /usr/local/bin/fastproxy /tmp/fastproxy.c -lpthread
chmod +x /usr/local/bin/fastproxy
print_status "C proxy compiled and installed"

# =============================================================================
# Step 5: Create systemd Service for Fast Proxy
# =============================================================================
print_status "Creating systemd service..."

cat > /etc/systemd/system/fastproxy.service << 'EOF'
[Unit]
Description=High-Performance HTTP Tunnel Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/fastproxy
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fastproxy
systemctl start fastproxy
print_status "Fast proxy service started"

# =============================================================================
# Step 6: Build and Configure BadVPN-UDPGW
# =============================================================================
print_status "Installing BadVPN-UDPGW for UDP support..."

cd /tmp
rm -rf badvpn 2>/dev/null
if git clone https://github.com/ambrop72/badvpn.git 2>/dev/null; then
    cd badvpn
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
    make > /dev/null 2>&1 && make install > /dev/null 2>&1
    print_status "BadVPN compiled and installed"
else
    print_warning "BadVPN compilation failed, downloading pre-built binary..."
    wget -q -O /usr/local/bin/badvpn-udpgw https://raw.githubusercontent.com/daybreakersx/premern/master/badvpn-udpgw 2>/dev/null || true
fi
chmod +x /usr/local/bin/badvpn-udpgw 2>/dev/null || true

# Create BadVPN service
cat > /etc/systemd/system/badvpn.service << 'EOF'
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 0.0.0.0:7300 --max-clients 1000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable badvpn
systemctl start badvpn
print_status "BadVPN-UDPGW service started on port 7300"

# =============================================================================
# Step 7: Configure Firewall
# =============================================================================
print_status "Configuring firewall..."

ufw allow 22/tcp 2>/dev/null || true
ufw allow 110/tcp 2>/dev/null || true
ufw allow 8880/tcp 2>/dev/null || true
ufw allow 7300/udp 2>/dev/null || true
ufw allow 7300/tcp 2>/dev/null || true
echo "y" | ufw enable 2>/dev/null || true

print_status "Firewall configured"

# =============================================================================
# Step 8: Create User and Generate Credentials
# =============================================================================
print_status "Creating tunnel user..."

TEST_USER="tunnel_user"
if ! id "$TEST_USER" &>/dev/null; then
    TEST_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
    useradd -m -s /bin/bash "$TEST_USER" 2>/dev/null || true
    echo "$TEST_USER:$TEST_PASSWORD" | chpasswd
    print_status "Created user: $TEST_USER"
else
    print_warning "User $TEST_USER already exists"
    TEST_PASSWORD="[Use existing password]"
fi

# =============================================================================
# Step 9: Display Results
# =============================================================================
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

sleep 2
echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
print_status "Checking service status..."

# Check services
if ss -tulpn 2>/dev/null | grep -q ":8880"; then
    echo -e "${GREEN}✓${NC} Fast Proxy (port 8880): Running"
else
    echo -e "${RED}✗${NC} Fast Proxy (port 8880): Not running"
fi

if ss -tulpn 2>/dev/null | grep -q ":110"; then
    echo -e "${GREEN}✓${NC} OpenSSH (port 110): Running"
else
    echo -e "${RED}✗${NC} OpenSSH (port 110): Not running"
fi

if ss -tulpn 2>/dev/null | grep -q ":7300"; then
    echo -e "${GREEN}✓${NC} BadVPN-UDPGW (port 7300): Running"
else
    echo -e "${RED}✗${NC} BadVPN-UDPGW (port 7300): Not running"
fi

echo ""
echo "=========================================="
echo "Connection Details"
echo "=========================================="
echo ""
echo "Server IP:       $SERVER_IP"
echo "Proxy Port:      8880"
echo "SSH Port:        110"
echo "UDPGW Port:      7300"
echo "Username:        $TEST_USER"
echo "Password:        $TEST_PASSWORD"
echo ""
echo "=========================================="
echo "HTTP Custom Configuration"
echo "=========================================="
echo ""
echo "Host: $SERVER_IP:8880"
echo "     or"
echo "Host: your-domain.com:8880 (if using Cloudflare)"
echo ""
echo "Payload:"
echo "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
echo ""
echo "=========================================="

