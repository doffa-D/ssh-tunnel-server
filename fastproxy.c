/*
 * High-Performance HTTP Tunnel Proxy (C)
 * 
 * Accepts HTTP CONNECT/WebSocket requests on port 8880
 * and forwards traffic to SSH server on port 110 (OpenSSH)
 * 
 * Compile: gcc -O3 -march=native -o fastproxy fastproxy.c -lpthread
 * Run: ./fastproxy
 */

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
#include <errno.h>
#include <fcntl.h>

#define LISTEN_PORT 8880
#define SSH_PORT 109
#define BUFFER_SIZE 1048576  /* 1MB buffer for high throughput */

typedef struct {
    int client_fd;
    int ssh_fd;
} connection_t;

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
    
    /* Read HTTP headers */
    while (header_len < sizeof(header_buf) - 1) {
        int n = recv(conn->client_fd, header_buf + header_len, 1, 0);
        if (n <= 0) goto cleanup;
        header_len++;
        if (header_len >= 4 && memcmp(header_buf + header_len - 4, "\r\n\r\n", 4) == 0) break;
    }
    
    /* Connect to SSH server */
    conn->ssh_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (conn->ssh_fd < 0) goto cleanup;
    optimize_socket(conn->ssh_fd);
    
    struct sockaddr_in ssh_addr = {.sin_family = AF_INET, .sin_port = htons(SSH_PORT)};
    ssh_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    if (connect(conn->ssh_fd, (struct sockaddr*)&ssh_addr, sizeof(ssh_addr)) < 0) {
        close(conn->ssh_fd);
        goto cleanup;
    }
    
    /* Send appropriate HTTP response */
    const char* response = (strstr(header_buf, "websocket") || strstr(header_buf, "Upgrade")) ?
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n" :
        "HTTP/1.1 200 Connection Established\r\n\r\n";
    send(conn->client_fd, response, strlen(response), 0);
    
    /* Create bidirectional pipe */
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

