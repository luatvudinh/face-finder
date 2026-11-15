/*
 * Công cụ nhỏ cho tools/check_no_network.sh: kiểm tra App Sandbox với entitlements của app có chặn mạng thật không.
 *
 *   netprobe listen          mở cổng TCP trên 127.0.0.1, in số cổng ra stdout, chờ kết nối (chạy không sandbox)
 *   netprobe connect <cổng>  thử kết nối TCP tới 127.0.0.1:<cổng> và thử phân giải một tên miền qua DNS
 *
 * Mã thoát của "connect": 0 = kết nối được (mạng mở), 3 = mọi đường đều bị chặn, 1 = lỗi khác.
 * Chỉ nói chuyện với chính máy này: không gửi gì ra ngoài.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int do_listen(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 1; }
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = 0};
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 8) < 0) { perror("bind/listen"); return 1; }
    socklen_t n = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &n);
    printf("%d\n", ntohs(a.sin_port));
    fflush(stdout);
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c >= 0) close(c);
    }
}

static int do_connect(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int tcp_ok = 0, tcp_err = 0;
    if (s < 0) {
        tcp_err = errno;
    } else {
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((unsigned short)port)};
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) tcp_ok = 1; else tcp_err = errno;
        close(s);
    }
    printf("tcp 127.0.0.1:%d: %s\n", port, tcp_ok ? "kết nối được" : strerror(tcp_err));

    // Phân giải tên đi qua mDNSResponder (Mach service), sandbox không có quyền mạng cũng phải chặn.
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *res = NULL;
    int g = getaddrinfo("localhost.", NULL, &hints, &res);
    if (res) freeaddrinfo(res);
    printf("dns: %s\n", g == 0 ? "phân giải được" : gai_strerror(g));

    if (tcp_ok) return 0;
    if (tcp_err == EPERM || tcp_err == EACCES) return 3;
    return 1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "listen") == 0) return do_listen();
    if (argc >= 3 && strcmp(argv[1], "connect") == 0) return do_connect(atoi(argv[2]));
    fprintf(stderr, "dùng: netprobe listen | netprobe connect <cổng>\n");
    return 1;
}
