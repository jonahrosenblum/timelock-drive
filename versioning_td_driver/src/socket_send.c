#include "socket_send.h"
#include "ipc_transport.h"
#include <time.h>

/* When non-zero, all communication goes through shared-memory IPC. */
int g_use_ipc = 0;

/* Pointer to the mapped shared-memory channel (client side). */
static ShmChannel *g_ipc_channel = NULL;

static unsigned long g_tcp_io_seq = 0;

static void log_tcp_io(const char *event,
                       int sock,
                       size_t requested,
                       size_t progress,
                       int err)
{
    // FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    // if (!fptr)
    // {
    //     return;
    // }

    // struct timespec ts;
    // clock_gettime(CLOCK_REALTIME, &ts);
    // setvbuf(fptr, NULL, _IONBF, 0);
    // fprintf(fptr,
    //         "tcp_io seq=%lu ts=%lld.%09ld event=%s sock=%d requested=%zu progress=%zu errno=%d (%s)\n",
    //         ++g_tcp_io_seq,
    //         (long long)ts.tv_sec,
    //         ts.tv_nsec,
    //         event,
    //         sock,
    //         requested,
    //         progress,
    //         err,
    //         strerror(err));
    // fclose(fptr);
}

static int send_all_tcp(int sock, const char *buf, size_t len)
{
    // log_tcp_io("send_begin", sock, len, 0, 0);
    size_t sent_total = 0;
    while (sent_total < len)
    {
        size_t before = sent_total;
        ssize_t sent_now = send(sock, buf + sent_total, len - sent_total, 0);
        if (sent_now < 0)
        {
            if (errno == EINTR)
            {
                // log_tcp_io("send_eintr", sock, len, sent_total, errno);
                continue;
            }
            // log_tcp_io("send_error", sock, len, sent_total, errno);
            return -1;
        }
        if (sent_now == 0)
        {
            // log_tcp_io("send_zero", sock, len, sent_total, 0);
            return -1;
        }
        sent_total += (size_t)sent_now;
        // if (sent_total - before < (len - before))
        // {
        //     log_tcp_io("send_partial", sock, len, sent_total, 0);
        // }
    }

    // log_tcp_io("send_done", sock, len, sent_total, 0);

    return 0;
}

static ssize_t recv_all_tcp(int sock, void *buf, size_t len)
{
    // log_tcp_io("recv_begin", sock, len, 0, 0);
    size_t recv_total = 0;

    while (recv_total < len)
    {
        size_t before = recv_total;
        ssize_t recv_now = recv(sock, (char *)buf + recv_total, len - recv_total, 0);
        if (recv_now < 0)
        {
            if (errno == EINTR)
            {
                // log_tcp_io("recv_eintr", sock, len, recv_total, errno);
                continue;
            }
            // log_tcp_io("recv_error", sock, len, recv_total, errno);
            return -1;
        }
        if (recv_now == 0)
        {
            // log_tcp_io("recv_eof", sock, len, recv_total, 0);
            return (ssize_t)recv_total;
        }

        recv_total += (size_t)recv_now;
        // if (recv_total - before < (len - before))
        // {
        //     log_tcp_io("recv_partial", sock, len, recv_total, 0);
        // }
    }

    // log_tcp_io("recv_done", sock, len, recv_total, 0);

    return (ssize_t)recv_total;
}

void ipc_transport_init_client(void)
{
    g_ipc_channel = ipc_open();
}

ssize_t gk_recv(void *buf, size_t len)
{
    if (g_use_ipc) {
        shm_pipe_read(&g_ipc_channel->s2c, buf, (uint32_t)len);
        return (ssize_t)len;
    }
    /* TCP path: conn_fd is defined in versioning.c and used globally. */
    extern int conn_fd;
    return recv_all_tcp(conn_fd, buf, len);
}

ssize_t gk_send(const void *buf, size_t len)
{
    if (g_use_ipc) {
        shm_pipe_write(&g_ipc_channel->c2s, buf, (uint32_t)len);
        return (ssize_t)len;
    }
    extern int conn_fd;
    if (send_all_tcp(conn_fd, (const char *)buf, len) != 0)
    {
        return -1;
    }
    return (ssize_t)len;
}

void tle_print(const char *str)
{
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }
    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(fptr, "%s\n", str);
    // fflush(fptr);
    fclose(fptr);
}

void tle_print1(const char *str, int d)
{
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }
    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(fptr, "%s %d\n", str, d);
    // fflush(fptr);
    fclose(fptr);
}

void tle_print3(const char *str, int a, int b, int c)
{
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }
    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(fptr, "%s %d %d %d\n", str, a, b, c);
    // fflush(fptr);
    fclose(fptr);
}

int send_message(const char *hostname, int port, const char *message, const long unsigned message_length, int sock)
{
    if (g_use_ipc) {
        /* IPC mode: write the message directly into the client→server pipe. */
        shm_pipe_write(&g_ipc_channel->c2s, message, (uint32_t)message_length);
        return -1;   /* conn_fd is unused in IPC mode */
    }

    if (message_length > (MAX_MSG_LENGTH))
    {
        // tle_print("Message exceeds maximum length");
        return -1;
    }
    // Connect to remote server
    if (sock == -1)
    {
        // log_tcp_io("connect_begin", sock, (size_t)message_length, 0, 0);
        struct addrinfo hints = {}, *addrs;
        char port_str[16] = {};

        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_protocol = IPPROTO_TCP;
        sprintf(port_str, "%d", port);

        if (getaddrinfo(hostname, port_str, &hints, &addrs) != 0)
        {
            log_tcp_io("getaddrinfo_failed", sock, (size_t)message_length, 0, errno);
            // tle_print("Failed to get addr info");
        }

        for (struct addrinfo *addr = addrs; addr != NULL; addr = addr->ai_next)
        {
            sock = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
            if (sock == -1)
                break;

            if (!addr->ai_addr)
            {
                sock = -1;
                continue;
            }
            if (!addr->ai_addrlen)
            {
                sock = -1;
                continue;
            }
            if (connect(sock, addr->ai_addr, addr->ai_addrlen) == 0)
            {
                // log_tcp_io("connect_ok", sock, (size_t)message_length, 0, 0);
                break;
            }

            close(sock);
            sock = -1;
        }
        freeaddrinfo(addrs);
        if (sock == -1)
        {
            log_tcp_io("connect_failed", sock, (size_t)message_length, 0, errno);
            // char buffer[ 256 ];
            // char *errorMsg = strerror_r( errno, buffer, 256 ); // GNU-specific version, Linux default
            // printf("Error %s\n", errorMsg); //return value has to be used since buffer might not be modified
            // throw std::runtime_error("Failed to connect\n");
            // tle_print("Error with socket resolution??\n");
        }
    }
    if (sock == -1 || !message || !message_length)
    {
        // tle_print("Missed something on send");
    }
    // Send message to remote server
    if (send_all_tcp(sock, message, message_length) != 0)
    {
        tle_print("Error sending on stream socket");
        log_tcp_io("send_message_failed", sock, (size_t)message_length, 0, errno);
        return -1;
    }

    // log_tcp_io("send_message_ok", sock, (size_t)message_length, (size_t)message_length, 0);
    return sock;
}