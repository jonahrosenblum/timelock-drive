#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "versioning.h"

extern BlockEntryList *freelist;
extern pthread_mutex_t freelist_lock;
extern BlockEntry **l2pmap;
extern unsigned int *p2lmap;
extern int current_vmd_block;
extern int current_tdmd_block;
extern int tdmd_idx;
extern int map_idx;
extern int conn_fd;
extern int versioning;
extern int recovery;
extern int verbose_cache_log;
extern L2PBlock *l2p_block;
extern TDMetadataLogBlock *td_md_block;

static unsigned char mock_recv_stream[1 << 20];
static size_t mock_recv_stream_len;
static size_t mock_recv_stream_pos;
static enum DiskCommand sent_cmds[64];
static uint32_t sent_payload_sizes[64];
static size_t sent_cmd_count;

static FILE *recovery_test_fopen(const char *path, const char *mode)
{
    if (path != NULL && strcmp(path, "/tmp/timelockdriver.log") == 0)
    {
        return tmpfile();
    }
    return fopen(path, mode);
}

static int recovery_test_fclose(FILE *stream)
{
    if (stream == NULL)
    {
        return 0;
    }
    return fclose(stream);
}

static int recovery_test_setvbuf(FILE *stream, char *buf, int mode, size_t size)
{
    if (stream == NULL)
    {
        return 0;
    }
    return setvbuf(stream, buf, mode, size);
}

static void mock_reset(void)
{
    mock_recv_stream_len = 0;
    mock_recv_stream_pos = 0;
    sent_cmd_count = 0;
    conn_fd = -1;
    memset(sent_payload_sizes, 0, sizeof(sent_payload_sizes));
}

static void mock_push_bytes(const void *data, size_t len)
{
    assert(mock_recv_stream_len + len <= sizeof(mock_recv_stream));
    memcpy(mock_recv_stream + mock_recv_stream_len, data, len);
    mock_recv_stream_len += len;
}

static void mock_push_u32_le(unsigned int value)
{
    unsigned char bytes[4];
    bytes[0] = (unsigned char)(value & 0xffu);
    bytes[1] = (unsigned char)((value >> 8) & 0xffu);
    bytes[2] = (unsigned char)((value >> 16) & 0xffu);
    bytes[3] = (unsigned char)((value >> 24) & 0xffu);
    mock_push_bytes(bytes, sizeof(bytes));
}

static void mock_push_identify_response(unsigned int log_head, unsigned int log_tail)
{
    mock_push_u32_le(log_head);
    mock_push_u32_le(log_tail);
}

static void mock_push_cache_block(unsigned int md_idx,
                                  unsigned int entry_offset,
                                  unsigned int keep_duration,
                                  unsigned int time_written)
{
    CachedTDMetadataBlock block;
    memset(&block, 0, sizeof(block));
    block.idx = md_idx;
    if (entry_offset < METADATA_ENTRIES_PER_BLOCK)
    {
        block.mdblock.arr[entry_offset].keep_duration = keep_duration;
        block.mdblock.arr[entry_offset].time_written = time_written;
    }
    mock_push_bytes(&block, sizeof(block));
}

static void l2p_block_init(L2PBlock *block, unsigned int seed, unsigned int ptr)
{
    memset(block, 0, sizeof(*block));
    block->seed = seed;
    block->ptr = ptr;
    for (unsigned int i = 0; i < LENGTH_VERSION_LOG_BLOCK; ++i)
    {
        block->map[i].logical_block_address = UINT32_MAX;
        block->map[i].physical_block_address = UINT32_MAX;
    }
}

static void mock_push_l2p_block(unsigned int seed,
                                unsigned int ptr,
                                unsigned int logical_block_address,
                                unsigned int physical_block_address)
{
    L2PBlock block;
    l2p_block_init(&block, seed, ptr);
    if (logical_block_address != UINT32_MAX)
    {
        block.map[0].logical_block_address = logical_block_address;
        block.map[0].physical_block_address = physical_block_address;
    }
    mock_push_bytes(&block, sizeof(block));
}

static void mock_push_hdlog_block(unsigned int pointer_next,
                                  unsigned int keep_duration,
                                  unsigned int current_time)
{
    TDMetadataLogBlock block;
    memset(&block, 0, sizeof(block));
    block.keep_duration = keep_duration;
    block.current_time = current_time;
    block.pointer_next = pointer_next;
    mock_push_bytes(&block, sizeof(block));
}

static void push_zeroed_cache_snapshot(void)
{
    for (unsigned int i = 0; i < TOTAL_NUM_METADATA_BLOCKS; ++i)
    {
        mock_push_cache_block(i, METADATA_ENTRIES_PER_BLOCK, 0, 0);
    }
}

static void mock_push_recovery_phase2_done(void)
{
    mock_push_u32_le(0xFFFFFFFFu);
}

static void populate_freelist(unsigned int count)
{
    for (unsigned int i = 0; i < count; ++i)
    {
        BlockEntry *entry = malloc(sizeof(BlockEntry));
        assert(entry != NULL);
        entry->physical_block_id = i;
        entry->keep_duration = 0;
        entry->time_written = 0;
        entry->next = NULL;
        enqueue_list(entry, freelist, &freelist_lock);
    }
}

static void reset_driver_globals(void)
{
    current_vmd_block = -1;
    current_tdmd_block = -1;
    tdmd_idx = 0;
    map_idx = 0;
    versioning = 1;
    recovery = 1;
    verbose_cache_log = 0;
}

int send_message(const char *hostname, int port, const char *message, const long unsigned message_length, int sock)
{
    (void)hostname;
    (void)port;
    (void)sock;
    assert(message != NULL);
    assert(message_length >= sizeof(MessageHeader));

    MessageHeader header;
    memcpy(&header, message, sizeof(header));
    assert(sent_cmd_count < (sizeof(sent_cmds) / sizeof(sent_cmds[0])));
    
    sent_cmds[sent_cmd_count] = header.disk_cmd;
    sent_payload_sizes[sent_cmd_count] = header.payload_size;
    
    // Validate payload_size for each command type
    size_t expected_min_msg_length = sizeof(header);
    
    switch (header.disk_cmd)
    {
        case IDENTIFY:
        case FINISH:
            // Control commands should have payload_size = 0
            assert(header.payload_size == 0);
            expected_min_msg_length = sizeof(header);
            break;
            
        case INITCOUNTERS:
        case READ:
            // These should have at least one DataRange
            assert(header.payload_size == (uint32_t)sizeof(DataRange));
            expected_min_msg_length = sizeof(header) + sizeof(DataRange);
            break;
            
        case WRITE:
            // WRITE should have payload_size matching actual message body
            // Minimum: header + 1 range = sizeof(header) + sizeof(DataRange)
            // payload_size should be message_length - sizeof(header)
            {
                uint32_t actual_payload_length = (uint32_t)(message_length - sizeof(header));
                assert(header.payload_size == actual_payload_length);
                assert(header.payload_size >= (uint32_t)sizeof(DataRange));
            }
            break;
            
        default:
            assert(0 && "Unknown command type");
    }
    
    // Verify message_length matches header + payload_size
    assert(message_length == sizeof(header) + header.payload_size);
    
    sent_cmd_count++;
    return 123;
}

ssize_t recv(int sockfd, void *buf, size_t len, int flags)
{
    (void)sockfd;
    (void)flags;
    assert(mock_recv_stream_pos + len <= mock_recv_stream_len);
    memcpy(buf, mock_recv_stream + mock_recv_stream_pos, len);
    mock_recv_stream_pos += len;
    return (ssize_t)len;
}

ssize_t gk_recv(void *buf, size_t len)
{
    assert(mock_recv_stream_pos + len <= mock_recv_stream_len);
    memcpy(buf, mock_recv_stream + mock_recv_stream_pos, len);
    mock_recv_stream_pos += len;
    return (ssize_t)len;
}

ssize_t gk_send(const void *buf, size_t len)
{
    (void)buf;
    (void)len;
    return (ssize_t)len;
}

int g_use_ipc = 0;

void ipc_transport_init_client(void)
{
}

bool bdus_run_0_1_1_(const struct bdus_ops *ops, const struct bdus_attrs *attrs, void *buffer)
{
    (void)ops;
    (void)attrs;
    (void)buffer;
    return true;
}

const char *bdus_get_error_message_0_1_0_(void)
{
    return "stub";
}

void tle_print(const char *str)
{
    (void)str;
}

void tle_print1(const char *str, int d)
{
    (void)str;
    (void)d;
}

void tle_print3(const char *str, int a, int b, int c)
{
    (void)str;
    (void)a;
    (void)b;
    (void)c;
}

#define fopen recovery_test_fopen
#define fclose recovery_test_fclose
#define setvbuf recovery_test_setvbuf
#include "../src/versioning.c"
#define CHECKER_WRITE_DENIED CHECKER_WRITE_DENIED_DRIVER
#define CHECKER_FRESHNESS_REJECT CHECKER_FRESHNESS_REJECT_DRIVER
#define main versioning_td_driver_embedded_main
#include "../src/versioning_td_driver.c"
#undef main
#undef CHECKER_FRESHNESS_REJECT
#undef CHECKER_WRITE_DENIED
#undef setvbuf
#undef fclose
#undef fopen

static void test_fetch_gatekeeper_log_state_reads_persisted_hd_head_and_tail(void)
{
    unsigned int log_head = 0;
    unsigned int log_tail = 0;

    mock_reset();
    mock_push_identify_response(1200, 1337);

    assert(fetch_gatekeeper_log_state(&log_head, &log_tail) == 0);
    assert(log_head == 1200);
    assert(log_tail == 1337);
    assert(sent_cmd_count == 1);
    assert(sent_cmds[0] == IDENTIFY);
    assert(mock_recv_stream_pos == mock_recv_stream_len);
}

static void test_init_driver_recovery_uses_hd_tail_and_bootstraps_log_positions(void)
{
    mock_reset();
    reset_driver_globals();

    mock_push_identify_response(1666, 1666);
    push_zeroed_cache_snapshot();
    mock_push_recovery_phase2_done();
    mock_push_l2p_block(0, 0, UINT32_MAX, UINT32_MAX);

    init_driver(0);

    assert(current_tdmd_block == 1666);
    assert(current_vmd_block == LENGTH_VERSION_LOG_BLOCK);
    assert(tdmd_idx == 2);
    assert(td_md_block->arr[0] == LENGTH_VERSION_LOG_BLOCK);
    assert(td_md_block->arr[1] == 1666);
    assert(sent_cmd_count == 3);
    assert(sent_cmds[0] == IDENTIFY);
    assert(sent_cmds[1] == INITCOUNTERS);
    assert(sent_cmds[2] == READ);
}

static void assert_driver_recovers_hd_log_tail_growth(unsigned int tail_growth)
{
    const unsigned int default_tail = LENGTH_TD_LOG_BLOCK - 2;
    const unsigned int persisted_head = default_tail;
    const unsigned int persisted_tail = default_tail + tail_growth;

    mock_reset();
    reset_driver_globals();

    mock_push_identify_response(persisted_head, persisted_tail);
    push_zeroed_cache_snapshot();
    mock_push_recovery_phase2_done();
    for (unsigned int pba = persisted_head; pba < persisted_tail; ++pba)
    {
        mock_push_hdlog_block(pba + 1, 60, 1000 + pba);
    }
    mock_push_l2p_block(0, 0, UINT32_MAX, UINT32_MAX);

    init_driver(0);

    assert(current_tdmd_block == (int)persisted_tail);
    assert(current_vmd_block == LENGTH_VERSION_LOG_BLOCK);
    assert(tdmd_idx == 2);
    assert(td_md_block->arr[0] == LENGTH_VERSION_LOG_BLOCK);
    assert(td_md_block->arr[1] == persisted_tail);
    assert(sent_cmd_count == (size_t)(3 + tail_growth));
    assert(sent_cmds[0] == IDENTIFY);
    assert(sent_cmds[1] == INITCOUNTERS);
    for (unsigned int i = 2; i < (unsigned int)(2 + tail_growth); ++i)
    {
        assert(sent_cmds[i] == READ);
    }
    assert(sent_cmds[2 + tail_growth] == READ);
    assert(mock_recv_stream_pos == mock_recv_stream_len);
}

static void test_init_driver_recovery_tracks_hd_tail_growth_across_restarts(void)
{
    assert_driver_recovers_hd_log_tail_growth(0);
    assert_driver_recovers_hd_log_tail_growth(1);
    assert_driver_recovers_hd_log_tail_growth(2);
}

static void test_init_driver_recovery_replays_version_metadata_chain(void)
{
    const unsigned int first_log_pba = LENGTH_VERSION_LOG_BLOCK;
    const unsigned int second_log_pba = 600;

    mock_reset();
    reset_driver_globals();

    mock_push_identify_response(1888, 1888);
    for (unsigned int md_idx = 0; md_idx < TOTAL_NUM_METADATA_BLOCKS; ++md_idx)
    {
        unsigned int offset = METADATA_ENTRIES_PER_BLOCK;
        unsigned int keep_duration = 0;
        unsigned int time_written = 0;

        if (md_idx == (first_log_pba / METADATA_ENTRIES_PER_BLOCK))
        {
            offset = first_log_pba % METADATA_ENTRIES_PER_BLOCK;
            keep_duration = 111;
            time_written = 11;
        }
        else if (md_idx == (second_log_pba / METADATA_ENTRIES_PER_BLOCK))
        {
            offset = second_log_pba % METADATA_ENTRIES_PER_BLOCK;
            keep_duration = 222;
            time_written = 22;
        }

        mock_push_cache_block(md_idx, offset, keep_duration, time_written);
    }
    mock_push_recovery_phase2_done();

    mock_push_l2p_block(7, second_log_pba, 7, 2000);
    mock_push_l2p_block(7, 601, 8, 2001);
    mock_push_l2p_block(0, 0, UINT32_MAX, UINT32_MAX);

    init_driver(0);

    assert(current_tdmd_block == 1888);
    assert(current_vmd_block == 601);
    assert(l2pmap[7] != NULL);
    assert(l2pmap[7]->physical_block_id == 2000);
    assert(l2pmap[7]->keep_duration == 111);
    assert(l2pmap[7]->time_written == 11);
    assert(l2pmap[8] != NULL);
    assert(l2pmap[8]->physical_block_id == 2001);
    assert(l2pmap[8]->keep_duration == 222);
    assert(l2pmap[8]->time_written == 22);
    assert(p2lmap[2000] == 7);
    assert(p2lmap[2001] == 8);
}

static void test_set_pointer_and_reset_tdmd_advances_hd_tail_and_pointer_next(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    current_tdmd_block = LENGTH_TD_LOG_BLOCK - 2;
    tdmd_idx = 99;
    td_md_block->pointer_next = 0;

    assert(set_pointer_and_reset_tdmd(1) == 0);
    assert(current_tdmd_block == (LENGTH_TD_LOG_BLOCK - 2));
    assert(td_md_block->pointer_next == (unsigned int)current_tdmd_block);
    assert(tdmd_idx == 0);
}

static void test_set_pointer_and_reset_vmd_sets_version_tail_and_ptr_consistently(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    current_vmd_block = -1;
    map_idx = 77;
    l2p_block->ptr = 42;

    assert(set_pointer_and_reset_vmd() == 0);
    assert(current_vmd_block == LENGTH_VERSION_LOG_BLOCK);
    assert(l2p_block->ptr == (unsigned int)current_vmd_block);
    assert(map_idx == 0);
}

int main(void)
{
    test_fetch_gatekeeper_log_state_reads_persisted_hd_head_and_tail();
    test_init_driver_recovery_uses_hd_tail_and_bootstraps_log_positions();
    test_init_driver_recovery_tracks_hd_tail_growth_across_restarts();
    test_init_driver_recovery_replays_version_metadata_chain();
    test_set_pointer_and_reset_tdmd_advances_hd_tail_and_pointer_next();
    test_set_pointer_and_reset_vmd_sets_version_tail_and_ptr_consistently();

    printf("PASS\n");
    return 0;
}