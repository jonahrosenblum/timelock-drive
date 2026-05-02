#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#ifdef _MSC_VER
#include <intrin.h>
#else
#include <x86intrin.h>
#endif

#include "constants.h"
#include "ipc_transport.h"

#define HOSTNAME "127.0.0.1"
#define PORT 10107
#define LOG_TAIL_START (LENGTH_TD_LOG_BLOCK - 2)
#define LOG_STATE_PBA (TOTAL_PHYSICAL_NUM_BLOCKS - 1)

typedef struct ClientState ClientState;
struct ClientState
{
    CachedTDMetadataBlock *cache;
    uint8_t *membership;
};

static int g_use_ipc = 0;
static ShmChannel *g_ipc_channel = NULL;

static int client_trace_enabled(void)
{
    const char *v = getenv("TL_CLIENT_TRACE");
    if (!v)
    {
        return 1;
    }
    if (v[0] == '\0' || strcmp(v, "0") == 0 || strcmp(v, "false") == 0 || strcmp(v, "off") == 0)
    {
        return 0;
    }
    return 1;
}

static int connect_checker(void)
{
    if (g_use_ipc)
    {
        if (g_ipc_channel == NULL)
        {
            g_ipc_channel = ipc_open();
        }
        return -1;
    }

    struct addrinfo hints;
    struct addrinfo *addrs = NULL;
    int fd = -1;
    char port_str[16];

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    snprintf(port_str, sizeof(port_str), "%d", PORT);

    if (getaddrinfo(HOSTNAME, port_str, &hints, &addrs) != 0)
    {
        return -1;
    }

    for (struct addrinfo *addr = addrs; addr != NULL; addr = addr->ai_next)
    {
        fd = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
        if (fd < 0)
        {
            continue;
        }

        if (connect(fd, addr->ai_addr, addr->ai_addrlen) == 0)
        {
            break;
        }

        close(fd);
        fd = -1;
    }

    freeaddrinfo(addrs);
    return fd;
}

static int send_all(int fd, const void *buf, size_t len)
{
    if (g_use_ipc)
    {
        (void)fd;
        shm_pipe_write(&g_ipc_channel->c2s, buf, (uint32_t)len);
        return 0;
    }

    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len)
    {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n <= 0)
        {
            return -1;
        }
        sent += (size_t)n;
    }
    return 0;
}

static int recv_all(int fd, void *buf, size_t len)
{
    if (g_use_ipc)
    {
        (void)fd;
        shm_pipe_read(&g_ipc_channel->s2c, buf, (uint32_t)len);
        return 0;
    }

    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len)
    {
        ssize_t n = recv(fd, p + got, len - got, MSG_WAITALL);
        if (n <= 0)
        {
            return -1;
        }
        got += (size_t)n;
    }
    return 0;
}

static unsigned int load_u32_le(const uint8_t *p)
{
    return ((unsigned int)p[0]) |
           ((unsigned int)p[1] << 8) |
           ((unsigned int)p[2] << 16) |
           ((unsigned int)p[3] << 24);
}

static int send_finish(int fd)
{
    MessageHeader hdr = {.payload_size = 0, .num_data_ranges = 0, .num_md_blocks = 0, .disk_cmd = FINISH};
    return send_all(fd, &hdr, sizeof(hdr));
}

static int read_single_block(int fd, unsigned int pba, uint8_t *payload);
static int identify_gatekeeper_state(int fd, unsigned int *log_head, unsigned int *log_tail);

static int peek_hdlog_header(int fd, unsigned int pba)
{
    uint8_t payload[BLOCK_SIZE];
    if (read_single_block(fd, pba, payload) != 0)
    {
        return -1;
    }

    const TDMetadataLogBlock *log = (const TDMetadataLogBlock *)payload;
    printf("HDLOG pba=%u keep=%u current=%u next=%u\n",
           pba,
           log->keep_duration,
           log->current_time,
           log->pointer_next);
    return 0;
}

static int anchor_from_tail(int fd)
{
    unsigned int log_head = 0;
    unsigned int log_tail = 0;
    uint8_t payload[BLOCK_SIZE];
    bool *visited = NULL;
    unsigned int curr = 0;

    if (identify_gatekeeper_state(fd, &log_head, &log_tail) != 0)
    {
        return -1;
    }

    // The gatekeeper treats log_tail as the next free slot (exclusive end),
    // so the anchor must come from the last committed block before tail.
    if (log_head == log_tail)
    {
        fprintf(stderr, "anchor-tail: empty log chain (head == tail == %u)\n", log_head);
        return -1;
    }

    visited = calloc(TOTAL_PHYSICAL_NUM_BLOCKS, sizeof(bool));
    if (!visited)
    {
        return -1;
    }

    curr = log_head;
    for (unsigned int steps = 0; steps < TOTAL_PHYSICAL_NUM_BLOCKS; ++steps)
    {
        if (curr >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            free(visited);
            fprintf(stderr, "anchor-tail: out-of-range log pba=%u\n", curr);
            return -1;
        }

        if (visited[curr])
        {
            free(visited);
            fprintf(stderr, "anchor-tail: cycle detected at pba=%u\n", curr);
            return -1;
        }
        visited[curr] = true;

        if (read_single_block(fd, curr, payload) != 0)
        {
            free(visited);
            return -1;
        }

        const TDMetadataLogBlock *log = (const TDMetadataLogBlock *)payload;
        if (log->pointer_next == log_tail)
        {
            printf("ANCHOR head=%u tail=%u keep=%u current=%u next=%u\n",
                   log_head,
                   curr,
                   log->keep_duration,
                   log->current_time,
                   log->pointer_next);
            free(visited);
            return 0;
        }

        if (log->pointer_next >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            free(visited);
            fprintf(stderr, "anchor-tail: out-of-range pointer_next=%u from pba=%u\n", log->pointer_next, curr);
            return -1;
        }

        curr = log->pointer_next;
    }

    free(visited);
    fprintf(stderr, "anchor-tail: exceeded traversal bound\n");
    return -1;
}

static int identify_gatekeeper_state(int fd, unsigned int *log_head, unsigned int *log_tail)
{
    MessageHeader hdr = {.payload_size = 0, .num_data_ranges = 0, .num_md_blocks = 0, .disk_cmd = IDENTIFY};
    uint8_t resp[2 * sizeof(unsigned int)];

    if (send_all(fd, &hdr, sizeof(hdr)) != 0)
    {
        return -1;
    }

    if (recv_all(fd, resp, sizeof(resp)) != 0)
    {
        return -1;
    }

    *log_head = load_u32_le(resp);
    *log_tail = load_u32_le(resp + sizeof(unsigned int));
    return 0;
}

static int init_counters(int fd, ClientState *st)
{
    enum { RECOVERY_MAX_MD_REQUEST = 4 };
    uint8_t msg[STD_MSG_HEADER_SIZE + DATA_RANGE_SIZE];
    MessageHeader hdr = {
        .payload_size = (uint32_t)sizeof(DataRange),
        .num_data_ranges = 1,
        .num_md_blocks = 0,
        .disk_cmd = INITCOUNTERS
    };
    DataRange dr = {.pba = 0, .num_blocks = 1};

    memcpy(msg, &hdr, sizeof(hdr));
    memcpy(msg + sizeof(hdr), &dr, sizeof(dr));

    if (send_all(fd, msg, sizeof(msg)) != 0)
    {
        return -1;
    }

    for (unsigned int i = 0; i < TOTAL_NUM_METADATA_BLOCKS; ++i)
    {
        if (recv_all(fd, &st->cache[i], sizeof(CachedTDMetadataBlock)) != 0)
        {
            return -1;
        }
        st->membership[i] = 0;
    }

    // Phase 2: Recovery cache request protocol.
    // Gatekeeper asks for needed md indices, we send them back, then receive
    // updated blocks for that replay step.
    for (;;) {
        uint32_t n_needed = 0;
        if (recv_all(fd, &n_needed, sizeof(n_needed)) != 0)
        {
            return -1;
        }
        if (n_needed == 0xFFFFFFFFU)
        {
            break;
        }

        if (n_needed > RECOVERY_MAX_MD_REQUEST)
        {
            return -1;
        }

        uint32_t needed_idx[RECOVERY_MAX_MD_REQUEST];
        for (uint32_t k = 0; k < n_needed; ++k)
        {
            if (recv_all(fd, &needed_idx[k], sizeof(uint32_t)) != 0)
            {
                return -1;
            }
        }

        for (uint32_t k = 0; k < n_needed; ++k)
        {
            uint32_t idx = needed_idx[k];
            if (idx >= TOTAL_NUM_METADATA_BLOCKS)
            {
                CachedTDMetadataBlock zero_block;
                memset(&zero_block, 0, sizeof(zero_block));
                if (send_all(fd, &zero_block, sizeof(zero_block)) != 0)
                {
                    return -1;
                }
            }
            else
            {
                if (send_all(fd, &st->cache[idx], sizeof(CachedTDMetadataBlock)) != 0)
                {
                    return -1;
                }
            }
        }

        uint32_t n_updated = 0;
        if (recv_all(fd, &n_updated, sizeof(n_updated)) != 0)
        {
            return -1;
        }

        for (uint32_t k = 0; k < n_updated; ++k)
        {
            CachedTDMetadataBlock updated;
            if (recv_all(fd, &updated, sizeof(updated)) != 0)
            {
                return -1;
            }
            if (updated.idx < TOTAL_NUM_METADATA_BLOCKS)
            {
                st->cache[updated.idx] = updated;
                st->membership[updated.idx] = 0;
            }
        }
    }

    return 0;
}

static void update_evictions(int fd, ClientState *st, uint8_t evict_count)
{
    if (evict_count == 0)
    {
        return;
    }

    CachedTDMetadataBlock *evicted = malloc(sizeof(CachedTDMetadataBlock) * evict_count);
    if (!evicted)
    {
        return;
    }

    if (recv_all(fd, evicted, sizeof(CachedTDMetadataBlock) * evict_count) != 0)
    {
        free(evicted);
        return;
    }

    for (uint8_t i = 0; i < evict_count; ++i)
    {
        unsigned int idx = evicted[i].idx;
        if (idx < TOTAL_NUM_METADATA_BLOCKS)
        {
            st->cache[idx] = evicted[i];
            st->membership[idx] = 0;
        }
    }

    free(evicted);
}

static int write_single_block(int fd, ClientState *st, unsigned int pba, const uint8_t *payload)
{
    unsigned int md_idx = pba / METADATA_ENTRIES_PER_BLOCK;
    if (md_idx >= TOTAL_NUM_METADATA_BLOCKS)
    {
        return -1;
    }

    MessageHeader hdr = {.payload_size = 0, .num_data_ranges = 1, .num_md_blocks = 0, .disk_cmd = WRITE};
    DataRange dr = {.pba = pba, .num_blocks = 1};

    if (!st->membership[md_idx])
    {
        hdr.num_md_blocks = 1;
    }

    hdr.payload_size = (uint32_t)(
        sizeof(DataRange) +
        ((size_t)hdr.num_md_blocks * sizeof(CachedTDMetadataBlock)) +
        BLOCK_SIZE);

    size_t msg_len = sizeof(hdr) + sizeof(dr) + ((size_t)hdr.num_md_blocks * sizeof(CachedTDMetadataBlock)) + BLOCK_SIZE;
    uint8_t *msg = malloc(msg_len);
    if (!msg)
    {
        return -1;
    }

    uint8_t *head = msg;
    memcpy(head, &hdr, sizeof(hdr));
    head += sizeof(hdr);
    memcpy(head, &dr, sizeof(dr));
    head += sizeof(dr);

    if (hdr.num_md_blocks)
    {
        memcpy(head, &st->cache[md_idx], sizeof(CachedTDMetadataBlock));
        head += sizeof(CachedTDMetadataBlock);
        st->membership[md_idx] = 1;
    }

    memcpy(head, payload, BLOCK_SIZE);

    if (send_all(fd, msg, msg_len) != 0)
    {
        free(msg);
        return -1;
    }
    free(msg);

    uint8_t resp_code = 0;
    if (recv_all(fd, &resp_code, sizeof(resp_code)) != 0)
    {
        return -2;
    }

    if (resp_code > MAX_MD_BLOCKS_IN_HEADER)
    {
        // Checker returned an explicit write-denied or error status.
        return -3;
    }

    update_evictions(fd, st, resp_code);
    return 0;
}

static int flush_cache_with_sparse_writes(int fd, ClientState *st, unsigned int avoid_md_idx, unsigned int target_writes)
{
        uint8_t payload[BLOCK_SIZE];
        unsigned int successful = 0;
        unsigned int attempts = 0;
        unsigned int max_attempts = target_writes * 8;
        unsigned int md_space = TOTAL_NUM_METADATA_BLOCKS;

        if (target_writes == 0)
        {
            return 0;
    }

        if (md_space <= 1)
        {
            return -1;
        }

        while (successful < target_writes && attempts < max_attempts)
        {
            // Intentionally jump far in md index space so each write touches different metadata.
            unsigned int candidate_md = (17u + (attempts * 503u)) % md_space;
            if (candidate_md == avoid_md_idx)
            {
                attempts++;
                continue;
            }

            unsigned int pba = candidate_md * METADATA_ENTRIES_PER_BLOCK;
            if (pba >= TOTAL_PHYSICAL_NUM_BLOCKS - 1)
            {
                attempts++;
                continue;
            }

            memset(payload, (uint8_t)((0xA0u + successful) & 0xffu), BLOCK_SIZE);
            int rc = write_single_block(fd, st, pba, payload);
            if (rc == 0)
            {
                successful++;
            }
            else if (rc == -3)
            {
                // Write denied by checker for this candidate; try another sparse location.
            }
            else
            {
                return -1;
            }

            attempts++;
        }

        if (successful < target_writes)
        {
            fprintf(stderr,
                    "cache flush sparse writes incomplete: wanted=%u got=%u attempts=%u\n",
                    target_writes,
                    successful,
                    attempts);
            return -1;
        }

        if (client_trace_enabled())
        {
            fprintf(stderr,
                    "[tl-client] cache flush complete: sparse_writes=%u attempts=%u\n",
                    successful,
                    attempts);
        }

        return 0;
    }

static int write_hdlog_block(int fd, ClientState *st, unsigned int target_pba, unsigned int log_pba, const uint8_t *payload)
{
    unsigned int md_indices[MAX_MD_BLOCKS_IN_HEADER];
    uint8_t md_count = 0;
    unsigned int log_md_idx = log_pba / METADATA_ENTRIES_PER_BLOCK;
    unsigned int target_md_idx = target_pba / METADATA_ENTRIES_PER_BLOCK;

    if (log_md_idx >= TOTAL_NUM_METADATA_BLOCKS || target_md_idx >= TOTAL_NUM_METADATA_BLOCKS)
    {
        return -1;
    }

    if (!st->membership[log_md_idx])
    {
        md_indices[md_count++] = log_md_idx;
    }

    if (target_md_idx != log_md_idx && !st->membership[target_md_idx])
    {
        md_indices[md_count++] = target_md_idx;
    }

    if (client_trace_enabled())
    {
        fprintf(
            stderr,
            "[tl-client] write-hdlog log_pba=%u target_pba=%u log_md_idx=%u target_md_idx=%u md_count=%u mem_log=%u mem_target=%u\n",
            log_pba,
            target_pba,
            log_md_idx,
            target_md_idx,
            (unsigned int)md_count,
            (unsigned int)st->membership[log_md_idx],
            (unsigned int)st->membership[target_md_idx]);
    }

    MessageHeader hdr = {.payload_size = 0, .num_data_ranges = 1, .num_md_blocks = md_count, .disk_cmd = WRITE};
    DataRange dr = {.pba = log_pba, .num_blocks = 1};

    hdr.payload_size = (uint32_t)(
        sizeof(DataRange) +
        ((size_t)md_count * sizeof(CachedTDMetadataBlock)) +
        BLOCK_SIZE);

    size_t msg_len = sizeof(hdr) + sizeof(dr) + ((size_t)md_count * sizeof(CachedTDMetadataBlock)) + BLOCK_SIZE;
    uint8_t *msg = malloc(msg_len);
    if (!msg)
    {
        return -1;
    }

    uint8_t *head = msg;
    memcpy(head, &hdr, sizeof(hdr));
    head += sizeof(hdr);
    memcpy(head, &dr, sizeof(dr));
    head += sizeof(dr);

    for (uint8_t i = 0; i < md_count; ++i)
    {
        unsigned int idx = md_indices[i];
        if (client_trace_enabled())
        {
            const CachedTDMetadataBlock *blk = &st->cache[idx];
            const unsigned char *h = (const unsigned char *)blk->hash;
            fprintf(
                stderr,
                "[tl-client]   md[%u]=%u counter=%u hash_prefix=%02x%02x%02x%02x\n",
                (unsigned int)i,
                idx,
                blk->counter,
                (unsigned int)h[0],
                (unsigned int)h[1],
                (unsigned int)h[2],
                (unsigned int)h[3]);
        }
        memcpy(head, &st->cache[idx], sizeof(CachedTDMetadataBlock));
        head += sizeof(CachedTDMetadataBlock);
        st->membership[idx] = 1;
    }

    memcpy(head, payload, BLOCK_SIZE);

    if (send_all(fd, msg, msg_len) != 0)
    {
        free(msg);
        return -1;
    }
    free(msg);

    uint8_t resp_code = 0;
    if (recv_all(fd, &resp_code, sizeof(resp_code)) != 0)
    {
        return -2;
    }

    if (client_trace_enabled())
    {
        fprintf(stderr, "[tl-client] write-hdlog response_code=%u\n", (unsigned int)resp_code);
    }

    if (resp_code > MAX_MD_BLOCKS_IN_HEADER)
    {
        if (client_trace_enabled())
        {
            fprintf(stderr, "[tl-client] write-hdlog rejected by gatekeeper status=%u\n", (unsigned int)resp_code);
        }
        return -3;
    }

    update_evictions(fd, st, resp_code);
    return 0;
}

static int read_single_block(int fd, unsigned int pba, uint8_t *payload)
{
    MessageHeader hdr = {
        .payload_size = (uint32_t)sizeof(DataRange),
        .num_data_ranges = 1,
        .num_md_blocks = 0,
        .disk_cmd = READ
    };
    DataRange dr = {.pba = pba, .num_blocks = 1};
    uint8_t msg[STD_MSG_HEADER_SIZE + DATA_RANGE_SIZE];

    memcpy(msg, &hdr, sizeof(hdr));
    memcpy(msg + sizeof(hdr), &dr, sizeof(dr));

    if (send_all(fd, msg, sizeof(msg)) != 0)
    {
        return -1;
    }

    if (recv_all(fd, payload, BLOCK_SIZE) != 0)
    {
        return -1;
    }

    return 0;
}

static void build_hdlog_payload(uint8_t *payload,
                                unsigned int target_pba,
                                unsigned int keep_duration,
                                unsigned int current_time,
                                unsigned int pointer_next)
{
    memset(payload, 0, BLOCK_SIZE);
    TDMetadataLogBlock *log = (TDMetadataLogBlock *)payload;
    for (unsigned int i = 0; i < LENGTH_TD_LOG_BLOCK; ++i)
    {
        // Use invalid PBAs for unused entries so one command performs one logical transition.
        log->arr[i] = UINT32_MAX;
    }
    log->arr[0] = target_pba;
    log->keep_duration = keep_duration;
    log->current_time = current_time;
    log->pointer_next = pointer_next;
}

static void build_log_state_payload(uint8_t *payload,
                                    unsigned int log_head,
                                    unsigned int log_tail)
{
    memset(payload, 0, BLOCK_SIZE);
    payload[0] = (uint8_t)(log_head & 0xffu);
    payload[1] = (uint8_t)((log_head >> 8) & 0xffu);
    payload[2] = (uint8_t)((log_head >> 16) & 0xffu);
    payload[3] = (uint8_t)((log_head >> 24) & 0xffu);

    payload[4] = (uint8_t)(log_tail & 0xffu);
    payload[5] = (uint8_t)((log_tail >> 8) & 0xffu);
    payload[6] = (uint8_t)((log_tail >> 16) & 0xffu);
    payload[7] = (uint8_t)((log_tail >> 24) & 0xffu);
}

static unsigned int tsc32_now(void)
{
    return (unsigned int)(__rdtsc() >> 32);
}

static int inspect_pba(const ClientState *st, unsigned int pba)
{
    unsigned int md_idx = pba / METADATA_ENTRIES_PER_BLOCK;
    unsigned int off = pba % METADATA_ENTRIES_PER_BLOCK;

    if (md_idx >= TOTAL_NUM_METADATA_BLOCKS)
    {
        return -1;
    }

    MetadataEntry e = st->cache[md_idx].mdblock.arr[off];
    unsigned int now = tsc32_now();
    const char *state = "COUNTDOWN";

    if ((e.time_written % 2) == 0)
    {
        state = "FROZEN";
    }
    else if (now > e.keep_duration)
    {
        state = "FREE";
    }

    printf("PBA=%u KEEP=%u TIME=%u NOW=%u STATE=%s\n",
           pba,
           e.keep_duration,
           e.time_written,
           now,
           state);

    return 0;
}

static int run_freshness_replay(int fd, ClientState *st)
{
    uint8_t payload[BLOCK_SIZE];

    // Snapshot a valid old copy for md_idx=3 before we trigger a real metadata mutation.
    unsigned int stale_md_idx = 2000U / METADATA_ENTRIES_PER_BLOCK;
    CachedTDMetadataBlock stale_snapshot = st->cache[stale_md_idx];

    unsigned int target_pba = stale_md_idx * METADATA_ENTRIES_PER_BLOCK;
    unsigned int stale_counter = stale_snapshot.counter;

    // Step 1: perform one valid HD-log transition that touches target_pba.
    // This causes the checker to run ComputeLogUpdates and increment freshness
    // for the corresponding metadata block.
    unsigned int log_head = 0;
    unsigned int log_tail = 0;
    if (identify_gatekeeper_state(fd, &log_head, &log_tail) != 0)
    {
        return -1;
    }
    unsigned int pointer_next = log_tail + 1;
    unsigned int now = tsc32_now();

    build_hdlog_payload(payload, target_pba, 1, now, pointer_next);
    if (write_hdlog_block(fd, st, target_pba, log_tail, payload) != 0)
    {
        fprintf(stderr, "failed to apply valid hdlog mutation before stale replay\n");
        return -1;
    }

    // Force cache turnover so stale replay is checked after resident entries are displaced.
    if (flush_cache_with_sparse_writes(fd, st, stale_md_idx, 10) != 0)
    {
        fprintf(stderr, "failed to flush cache with sparse metadata writes before stale replay\n");
        return -1;
    }

    // Step 2: send stale metadata snapshot from before the mutation and
    // require a freshness rejection.
    if (identify_gatekeeper_state(fd, &log_head, &log_tail) != 0)
    {
        return -1;
    }
    pointer_next = log_tail + 1;
    now = tsc32_now();

    build_hdlog_payload(payload, target_pba, 1, now, pointer_next);

    unsigned int log_md_idx = log_tail / METADATA_ENTRIES_PER_BLOCK;
    if (log_md_idx >= TOTAL_NUM_METADATA_BLOCKS)
    {
        return -1;
    }

    uint8_t md_count = (log_md_idx == stale_md_idx) ? 1 : 2;
    MessageHeader hdr = {.payload_size = 0, .num_data_ranges = 1, .num_md_blocks = md_count, .disk_cmd = WRITE};
    DataRange dr = {.pba = log_tail, .num_blocks = 1};

    hdr.payload_size = (uint32_t)(
        sizeof(DataRange) +
        ((size_t)md_count * sizeof(CachedTDMetadataBlock)) +
        BLOCK_SIZE);

    size_t msg_len = sizeof(hdr) + sizeof(dr) + ((size_t)md_count * sizeof(CachedTDMetadataBlock)) + BLOCK_SIZE;
    uint8_t *msg = malloc(msg_len);
    if (!msg)
    {
        return -1;
    }

    uint8_t *head = msg;
    memcpy(head, &hdr, sizeof(hdr));
    head += sizeof(hdr);
    memcpy(head, &dr, sizeof(dr));
    head += sizeof(dr);

    if (log_md_idx == stale_md_idx)
    {
        memcpy(head, &stale_snapshot, sizeof(CachedTDMetadataBlock));
        head += sizeof(CachedTDMetadataBlock);
    }
    else
    {
        memcpy(head, &st->cache[log_md_idx], sizeof(CachedTDMetadataBlock));
        head += sizeof(CachedTDMetadataBlock);
        memcpy(head, &stale_snapshot, sizeof(CachedTDMetadataBlock));
        head += sizeof(CachedTDMetadataBlock);
    }

    memcpy(head, payload, BLOCK_SIZE);
    if (send_all(fd, msg, msg_len) != 0)
    {
        free(msg);
        return -1;
    }
    free(msg);

    uint8_t resp_code = 0;
    if (recv_all(fd, &resp_code, sizeof(resp_code)) != 0)
    {
        return -2;
    }

    int rc = 0;
    if (resp_code > MAX_MD_BLOCKS_IN_HEADER)
    {
        rc = -3;
    }
    else
    {
        update_evictions(fd, st, resp_code);
    }

    printf("FRESHNESS_REPLAY md_idx=%u sent_stale=%u rc=%d\n",
           stale_md_idx,
           stale_counter,
           rc);

    // We expect explicit rejection from checker status byte (>MAX_MD_BLOCKS_IN_HEADER).
    if (rc != -3)
    {
        return -1;
    }

    // Soft rejection should not kill the checker; confirm subsequent command still works.
    if (read_single_block(fd, target_pba, payload) != 0)
    {
        fprintf(stderr, "checker did not stay alive after stale-counter rejection\n");
        return -1;
    }

    return 0;
}

static int run_action(const char *action, unsigned int pba, unsigned int a, unsigned int b, unsigned int c, unsigned int d)
{
    int fd = connect_checker();
    if (!g_use_ipc && fd < 0)
    {
        fprintf(stderr, "connect failed\n");
        return 2;
    }

    ClientState st = {
        .cache = calloc(TOTAL_NUM_METADATA_BLOCKS, sizeof(CachedTDMetadataBlock)),
        .membership = calloc(TOTAL_NUM_METADATA_BLOCKS, sizeof(uint8_t)),
    };

    bool is_finish_action = (strcmp(action, "finish") == 0);
    bool is_identify_action = (strcmp(action, "identify") == 0);
    bool peek_only = (strcmp(action, "peek-identify") == 0) ||
                     (strcmp(action, "peek-hdlog") == 0) ||
                     (strcmp(action, "anchor-tail") == 0);
    bool skip_init = peek_only || is_finish_action || is_identify_action;

    if (!st.cache || !st.membership)
    {
        if (!g_use_ipc && fd >= 0)
        {
            close(fd);
        }
        free(st.cache);
        free(st.membership);
        return 2;
    }

    if (!skip_init && init_counters(fd, &st) != 0)
    {
        fprintf(stderr, "initcounters failed\n");
        if (!g_use_ipc && fd >= 0)
        {
            close(fd);
        }
        free(st.cache);
        free(st.membership);
        return 2;
    }

    int rc = 0;
    uint8_t payload[BLOCK_SIZE];

    if (strcmp(action, "write-data") == 0)
    {
        memset(payload, (uint8_t)(a & 0xffu), sizeof(payload));
        rc = write_single_block(fd, &st, pba, payload);
    }
    else if (strcmp(action, "write-hdlog") == 0)
    {
        // args: pba=<target_pba>, a=<log_pba>, b=<keep_duration>, c=<current_time>, d=<pointer_next>
        build_hdlog_payload(payload, pba, b, c, d);
        rc = write_hdlog_block(fd, &st, pba, a, payload);
    }
    else if (strcmp(action, "inspect") == 0)
    {
        rc = inspect_pba(&st, pba);
    }
    else if (strcmp(action, "log-tail") == 0)
    {
        if (read_single_block(fd, LOG_STATE_PBA, payload) != 0)
        {
            rc = -1;
        }
        else
        {
            unsigned int tail = load_u32_le(payload + sizeof(unsigned int));
            printf("%u\n", tail);
            rc = 0;
        }
    }
    else if (strcmp(action, "identify") == 0)
    {
        unsigned int log_head = 0;
        unsigned int log_tail = 0;
        rc = identify_gatekeeper_state(fd, &log_head, &log_tail);
        if (rc == 0)
        {
            printf("IDENTIFY head=%u tail=%u\n", log_head, log_tail);
        }
    }
    else if (strcmp(action, "peek-identify") == 0)
    {
        unsigned int log_head = 0;
        unsigned int log_tail = 0;
        rc = identify_gatekeeper_state(fd, &log_head, &log_tail);
        if (rc == 0)
        {
            printf("IDENTIFY head=%u tail=%u\n", log_head, log_tail);
        }
    }
    else if (strcmp(action, "peek-hdlog") == 0)
    {
        rc = peek_hdlog_header(fd, pba);
    }
    else if (strcmp(action, "anchor-tail") == 0)
    {
        rc = anchor_from_tail(fd);
    }
    else if (strcmp(action, "write-log-state") == 0)
    {
        build_log_state_payload(payload, a, b);
        rc = write_single_block(fd, &st, LOG_STATE_PBA, payload);
    }
    else if (strcmp(action, "tsc32") == 0)
    {
        printf("%u\n", tsc32_now());
        rc = 0;
    }
    else if (strcmp(action, "freshness-replay") == 0)
    {
        rc = run_freshness_replay(fd, &st);
    }
    else if (strcmp(action, "finish") == 0)
    {
        rc = 0;
    }
    else    {
        fprintf(stderr, "unknown action: %s\n", action);
        rc = 2;
    }

    // Regular actions use FINISH to stop gatekeeper cleanly.
    // Peek actions are read-only probes against a running gatekeeper instance
    // and must not alter persistent state.
    if (!peek_only)
    {
        send_finish(fd);
    }
    if (!g_use_ipc && fd >= 0)
    {
        close(fd);
    }
    free(st.cache);
    free(st.membership);

    if (rc == -2)
    {
        return 1;
    }
    if (rc != 0)
    {
        return 2;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int argi = 1;
    if (argc > 1 && strcmp(argv[1], "--ipc") == 0)
    {
        g_use_ipc = 1;
        argi = 2;
    }
    else
    {
        const char *env_use_ipc = getenv("E2E_USE_IPC");
        if (env_use_ipc && strcmp(env_use_ipc, "1") == 0)
        {
            g_use_ipc = 1;
        }
    }

    if (argc - argi < 2)
    {
        fprintf(stderr, "usage: %s [--ipc] <action> <pba> [a] [b] [c] [d]\n", argv[0]);
        return 2;
    }

    const char *action = argv[argi];
    unsigned int pba = (unsigned int)strtoul(argv[argi + 1], NULL, 10);
    unsigned int a = (argc > argi + 2) ? (unsigned int)strtoul(argv[argi + 2], NULL, 10) : 0;
    unsigned int b = (argc > argi + 3) ? (unsigned int)strtoul(argv[argi + 3], NULL, 10) : 0;
    unsigned int c = (argc > argi + 4) ? (unsigned int)strtoul(argv[argi + 4], NULL, 10) : 0;
    unsigned int d = (argc > argi + 5) ? (unsigned int)strtoul(argv[argi + 5], NULL, 10) : 0;

    return run_action(action, pba, a, b, c, d);
}
