#include "versioning.h"
#include "socket_send.h"
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>

extern BlockEntry **l2pmap;
extern L2PBlock *l2p_block;
extern TDMetadataLogBlock *td_md_block;
extern pthread_mutex_t write_lock;
extern int current_tdmd_block;
extern int tdmd_idx;
extern int persisted_tdmd_log_head;
extern int persisted_tdmd_log_tail;
int once = 1;
int recovery = 0;
int finish = 0;
int no_sec = 0;
int no_gc_epoch = 0;
#ifndef VERSIONING_READ_ONLY_MODE_DEFINED
#define VERSIONING_READ_ONLY_MODE_DEFINED
int read_only_mode = 0;
#else
extern int read_only_mode;
#endif
extern int verbose_cache_log;

static const uint8_t CHECKER_WRITE_DENIED = 255;
static const uint8_t CHECKER_FRESHNESS_REJECT = 254;

static const char *driver_mode_to_str(int mode)
{
    switch (mode)
    {
    case MODE_NORMAL:
        return "normal";
    case MODE_VERSIONING:
        return "versioning";
    case MODE_BAREBONES:
        return "barebones";
    default:
        return "unknown";
    }
}

static int parse_driver_mode(const char *mode_str, int *mode_out)
{
    if (strcmp(mode_str, "normal") == 0)
    {
        *mode_out = MODE_NORMAL;
        return 0;
    }
    if (strcmp(mode_str, "versioning") == 0)
    {
        *mode_out = MODE_VERSIONING;
        return 0;
    }
    if (strcmp(mode_str, "barebones") == 0)
    {
        *mode_out = MODE_BAREBONES;
        return 0;
    }
    return -1;
}

static void apply_driver_mode(int mode)
{
    driver_mode = mode;
    switch (mode)
    {
    case MODE_NORMAL:
        versioning_metadata = 1;
        td_metadata = 1;
        break;
    case MODE_VERSIONING:
        versioning_metadata = 1;
        td_metadata = 0;
        no_sec = 1;
        break;
    case MODE_BAREBONES:
        versioning_metadata = 0;
        td_metadata = 0;
        no_sec = 1;
        break;
    default:
        versioning_metadata = 1;
        td_metadata = 1;
        driver_mode = MODE_NORMAL;
        break;
    }
}

static unsigned int bytes_to_uint32_le(const uint8_t *bytes)
{
    return ((unsigned int)bytes[0]) |
           ((unsigned int)bytes[1] << 8) |
           ((unsigned int)bytes[2] << 16) |
           ((unsigned int)bytes[3] << 24);
}

static int md_block_already_queued(const unsigned int *md_blocks,
                                   unsigned int md_block_count,
                                   unsigned int md_block)
{
    for (unsigned int i = 0; i < md_block_count; ++i)
    {
        if (md_blocks[i] == md_block)
        {
            return 1;
        }
    }

    return 0;
}

static void add_tdlog_referenced_md_blocks(const TDMetadataLogBlock *hdlog,
                                           unsigned int *md_blocks,
                                           unsigned int *md_block_count)
{
    for (unsigned int i = 0; i < LENGTH_TD_LOG_BLOCK; ++i)
    {
        unsigned int pba = hdlog->arr[i];
        if (pba >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            continue;
        }

        unsigned int md_idx = pba / METADATA_ENTRIES_PER_BLOCK;
        if (md_idx >= TOTAL_NUM_METADATA_BLOCKS)
        {
            continue;
        }

        if (md_block_already_queued(md_blocks, *md_block_count, md_idx))
        {
            continue;
        }

        if (*md_block_count >= MAX_MD_BLOCKS_IN_HEADER)
        {
            return;
        }

        md_blocks[(*md_block_count)++] = md_idx;
    }
}

int fetch_gatekeeper_log_state(unsigned int *log_head, unsigned int *log_tail)
{
    uint8_t msg_buffer[STD_MSG_HEADER_SIZE] = {0};
    uint8_t response[2 * sizeof(unsigned int)] = {0};
    MessageHeader header = {.payload_size = 0, .num_data_ranges = 0, .num_md_blocks = 0, .disk_cmd = IDENTIFY};

    header.payload_size = 0;
    memcpy(msg_buffer, &header, sizeof(header));
    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, (const char *)msg_buffer, sizeof(header), conn_fd);
    int rval = (int)gk_recv(response, sizeof(response));
    if (rval != (int)sizeof(response))
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "identify RVAL is %d, expected is %zu\n", rval, sizeof(response));
        fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
        fclose(fptr);
        return -1;
    }

    *log_head = bytes_to_uint32_le(response);
    *log_tail = bytes_to_uint32_le(response + sizeof(unsigned int));
    return 0;
}

static void log_write_rejection_context(uint64_t write_buffer_offset,
                                        uint32_t write_buffer_size,
                                        const MessageHeader *header,
                                        const DataRange *ranges,
                                        unsigned int range_count,
                                        const unsigned int *md_blocks,
                                        uint8_t status)
{
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }

    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(fptr,
            "write reject status=%u cmd=%s lba=%lu size=%u data_ranges=%u md_blocks=%u\n",
            (unsigned int)status,
            enum_to_str(header->disk_cmd),
            (unsigned long)(write_buffer_offset / BLOCK_SIZE),
            (unsigned int)write_buffer_size,
            range_count,
            (unsigned int)header->num_md_blocks);

    unsigned int max_ranges = range_count < 4 ? range_count : 4;
    for (unsigned int i = 0; i < max_ranges; ++i)
    {
        fprintf(fptr,
                "  range[%u]: pba=%u blocks=%u\n",
                i,
                ranges[i].pba,
                (unsigned int)ranges[i].num_blocks);
    }

    unsigned int max_md = header->num_md_blocks < 4 ? header->num_md_blocks : 4;
    for (unsigned int i = 0; i < max_md; ++i)
    {
        fprintf(fptr, "  md_block[%u]=%u\n", i, md_blocks[i]);
    }

    fclose(fptr);
}

void init_driver(unsigned int recovery_timestamp)
{
    fclose(fopen("/tmp/timelockdriver.log", "w"));

    apply_driver_mode(driver_mode);

    FILE *mode_fptr = fopen("/tmp/timelockdriver.log", "a");
    if (mode_fptr)
    {
        setvbuf(mode_fptr, NULL, _IONBF, 0);
        fprintf(mode_fptr,
                "startup mode=%s versioning_metadata=%d td_metadata=%d no_sec=%d\n",
                driver_mode_to_str(driver_mode),
                versioning_metadata,
                td_metadata,
                no_sec);
        fclose(mode_fptr);
    }

    versioning_init();

    if (td_metadata)
    {
        unsigned int log_head = 0;
        unsigned int log_tail = 0;
        if (fetch_gatekeeper_log_state(&log_head, &log_tail) == 0)
        {
            // Gatekeeper only persists the HD metadata log state (head and tail)
            // Both log_head and log_tail are for the HD log, not VMD
            persisted_tdmd_log_head = (int)log_head;
            persisted_tdmd_log_tail = (int)log_tail;
            current_tdmd_block = (int)log_tail;  // Use log_tail for current HD log position
            tdmd_idx = 0;
            
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
                fprintf(fptr,
                    "Startup: timestamp_recovery=%d recovery_timestamp=%u cli_recovery_flag=%d read_only=%d gatekeeper returned log_head=%u log_tail=%u (both for HD log)\n",
                    recovery_timestamp != 0,
                    recovery_timestamp,
                    recovery,
                    read_only_mode,
                    log_head, log_tail);
            fprintf(fptr, "  => current_tdmd_block=%d (from log_tail)\n", current_tdmd_block);
            fprintf(fptr, "  => current_vmd_block=%d (default, determined during scan)\n", current_vmd_block);
            fclose(fptr);
        }
        else
        {
            // If fetch fails, use defaults
            persisted_tdmd_log_head = LENGTH_TD_LOG_BLOCK - 2;
            persisted_tdmd_log_tail = LENGTH_TD_LOG_BLOCK - 2;
            current_tdmd_block = LENGTH_TD_LOG_BLOCK - 2;
        }
    }
    else
    {
        // TD-disabled modes: do not fetch or replay TD log state.
        persisted_tdmd_log_head = LENGTH_TD_LOG_BLOCK - 2;
        persisted_tdmd_log_tail = LENGTH_TD_LOG_BLOCK - 2;
        current_tdmd_block = LENGTH_TD_LOG_BLOCK - 2;
        tdmd_idx = 0;
    }

    current_vmd_block = LENGTH_VERSION_LOG_BLOCK;

    if (td_metadata)
    {
        build_cache();
    }
    scan_disk(recovery_timestamp, recovery, (unsigned int)versioning_metadata, (unsigned int)td_metadata);
    tle_print("done");
}

void init_daemons()
{
    int rc;
    pthread_t tid_move, tid_send, tid_metadata, tid_inc;

    rc = pthread_create(&tid_move, NULL, move_expired_to_free_daemon, NULL);
    rc = pthread_detach(tid_move);
    rc = pthread_create(&tid_metadata, NULL, metadata_daemon, NULL);
    rc = pthread_detach(tid_metadata);

    if (!no_sec)
    {
        rc = pthread_create(&tid_inc, NULL, epoch_flush_daemon, NULL);
        rc = pthread_detach(tid_inc);
        rc = pthread_create(&tid_send, NULL, gc_daemon, NULL);
        rc = pthread_detach(tid_send);
    }
}

int device_read(char *read_buffer, uint64_t read_buffer_offset, uint32_t read_buffer_size, struct bdus_ctx *ctx)
{
    // tle_print3("read", read_buffer_offset / BLOCK_SIZE, read_buffer_size / BLOCK_SIZE, 0);

    // Reset GC and SYNC triggers
    do_gc = 0;
    do_sync = 0;

    // Initialize entire buffer to zeros (for unmapped blocks)
    memset(read_buffer, 0, read_buffer_size);

    // Buffer and header setup
    char msg_buffer[STD_MSG_HEADER_SIZE + MAX_MAPPING_SIZE];
    unsigned int logical_block_address = read_buffer_offset / BLOCK_SIZE;
    unsigned int num_blocks = read_buffer_size / BLOCK_SIZE;
    MessageHeader header = {.payload_size = 0, .num_data_ranges = 0, .num_md_blocks = 0, .disk_cmd = READ};

    DataRange ranges[MAX_MAPPING_COUNT];
    bool unmapped[MAX_MAPPING_COUNT] = {0};

    // Prepare DataRange objects from logical to physical mapping
    // Only include mapped blocks; unmapped blocks will be filled with zeros
    unsigned int cur_range_start_pba = 0;
    unsigned int cur_range_blocks = 0;
    int range_count = 0;

    for (int i = 0; i < num_blocks; ++i)
    {
        int logical_index = logical_block_address + i;
        if (l2pmap[logical_index] != NULL)
        {
            unsigned int pba = l2pmap[logical_index]->physical_block_id;
            // tle_print3("found entry: ", logical_index, pba, 0);
            unmapped[i] = false;

            // Start/add to current range
            if (cur_range_blocks == 0)
            {
                cur_range_start_pba = pba;
                cur_range_blocks = 1;
            }
            else if (pba == cur_range_start_pba + cur_range_blocks)
            {
                // Range continues
                cur_range_blocks++;
            }
            else
            {
                // Range ends; save old range and start new
                ranges[range_count].pba = cur_range_start_pba;
                ranges[range_count].num_blocks = cur_range_blocks;
                range_count++;
                cur_range_start_pba = pba;
                cur_range_blocks = 1;
            }
        }
        else
        {
            // No mapping, treat as zeros
            unmapped[i] = true;

            // If we were building a range, save it before starting unmapped region
            if (cur_range_blocks > 0)
            {
                ranges[range_count].pba = cur_range_start_pba;
                ranges[range_count].num_blocks = cur_range_blocks;
                range_count++;
                cur_range_blocks = 0;
            }
        }
    }

    // Save final range, if any
    if (cur_range_blocks > 0)
    {
        ranges[range_count].pba = cur_range_start_pba;
        ranges[range_count].num_blocks = cur_range_blocks;
        range_count++;
    }

    // If there are mapped blocks, send READ request to gatekeeper
    if (range_count > 0)
    {
        header.num_data_ranges = range_count;
        header.payload_size = (uint32_t)(sizeof(DataRange) * range_count);

        // Write header and ranges to msg_buffer
        memcpy(msg_buffer, &header, sizeof(header));
        char *buffer_head = msg_buffer + sizeof(header);
        memcpy(buffer_head, ranges, sizeof(DataRange) * range_count);

        // tle_print3("read", ranges[0].pba, ranges[0].num_blocks, (buffer_head - msg_buffer));
        conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, msg_buffer,
                               sizeof(header) + sizeof(DataRange) * range_count, conn_fd);
        
        // Calculate total size of mapped data
        int total_mapped_blocks = 0;
        for (int i = 0; i < range_count; ++i)
        {
            total_mapped_blocks += ranges[i].num_blocks;
        }
        int total_mapped_size = total_mapped_blocks * BLOCK_SIZE;

        // Dynamically allocate buffer for mapped data
        char *temp_read_buffer = malloc(total_mapped_size);
        if (temp_read_buffer == NULL)
        {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "Failed to allocate temp_read_buffer for %d bytes\n", total_mapped_size);
            fclose(fptr);
            return -1;
        }

        int rval = (int)gk_recv(temp_read_buffer, total_mapped_size);

        // Handle recv errors
        if (rval != total_mapped_size)
        {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "read RVAL is %d, size is %d\n", rval, total_mapped_size);
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
            free(temp_read_buffer);
            return -1;
        }

        // Copy mapped block data into correct positions in read_buffer
        int src_offset = 0;
        for (int i = 0; i < num_blocks; ++i)
        {
            if (!unmapped[i])
            {
                memcpy(read_buffer + i * BLOCK_SIZE, temp_read_buffer + src_offset, BLOCK_SIZE);
                src_offset += BLOCK_SIZE;
            }
        }
        free(temp_read_buffer);
    }
    // tle_print("read5");

    return 0;
}

static int device_read_wrapper(char *buffer, uint64_t offset, uint32_t size, struct bdus_ctx *ctx)
{
    const uint32_t max_chunk_size = (uint32_t)MAX_MAPPING_COUNT * (uint32_t)BLOCK_SIZE;
    uint32_t remaining = size;
    uint64_t cur_offset = offset;
    char *cur_buffer = buffer;

    while (remaining > 0)
    {
        uint32_t chunk_size = remaining;
        if (chunk_size > max_chunk_size)
        {
            chunk_size = max_chunk_size;
        }

        int rc = device_read(cur_buffer, cur_offset, chunk_size, ctx);
        if (rc != 0)
        {
            return rc;
        }

        cur_offset += chunk_size;
        cur_buffer += chunk_size;
        remaining -= chunk_size;
    }

    return 0;
}

// Merge function, returns new length
unsigned int merge_ranges(DataRange* ranges, unsigned int count) {
    if (count == 0) return 0;
    unsigned int write_idx = 0;
    for (unsigned int read_idx = 1; read_idx < count; ++read_idx) {
        // Try to merge current range with the previous one in the output
        if (ranges[write_idx].pba + ranges[write_idx].num_blocks == ranges[read_idx].pba) {
            // Merge: extend previous range
            ranges[write_idx].num_blocks += ranges[read_idx].num_blocks;
        } else {
            // Copy over non-mergeable ranges
            ++write_idx;
            ranges[write_idx] = ranges[read_idx];
        }
    }
    // Return the new length
    return write_idx + 1;
}

int device_write(const char *write_buffer, uint64_t write_buffer_offset, uint32_t write_buffer_size, struct bdus_ctx *ctx, bool raw)
{
    // tle_print3("write", write_buffer_offset / BLOCK_SIZE, write_buffer_size / BLOCK_SIZE, 0);

    if (read_only_mode)
    {
        return -EROFS;
    }

    do_gc = 0;
    do_sync = 0;

    // Daemon start during initialization
    if ((versioning_metadata || td_metadata) && once)
    {
        once = 0;
        init_daemons();
    }

    char msg_buffer[MAX_MSG_LENGTH];
    char *buffer_head = msg_buffer;
    uint8_t success = 0;

    unsigned int logical_block_address = write_buffer_offset / BLOCK_SIZE;
    const int num_blocks_const = write_buffer_size / BLOCK_SIZE;
    int num_blocks = num_blocks_const;
    MessageHeader header = {.num_data_ranges = 0, .num_md_blocks = 0, .disk_cmd = WRITE};

    // Arrays to hold info for cache updates and ranges
    DataRange ranges[MAX_MAPPING_COUNT];
    L2PBlock version_md_block_local;
    unsigned int vmd_tie_breaker = 0;
    TDMetadataLogBlock td_md_block_local;
    unsigned int tdmd_tie_breaker = 0;
    // char md_block_local[BLOCK_SIZE * 2];
    unsigned int block_local_idx = 0;
    int version_offset = -1;
    int hd_offset = -1;
    memset(ranges, 0, sizeof(DataRange) * MAX_MAPPING_COUNT);
    unsigned int md_blocks[MAX_MD_BLOCKS_IN_HEADER];
    unsigned int touched_md_blocks[MAX_MD_BLOCKS_IN_HEADER];
    unsigned int touched_md_count = 0;
    unsigned int range_count = 0;
    unsigned int cur_lba_offset = 0;
    const char *write_fail_stage = "unknown";
    size_t msg_len = 0;

    RangeRet *free_range_ret;

    while (num_blocks > 0)
    {
        if (range_count >= MAX_MAPPING_COUNT)
        {
            tle_print("exceeded range blocks!");
            write_fail_stage = "range_count_exceeded";
            goto write_fail;
        }

        free_range_ret = find_free_range(logical_block_address,
                         (unsigned int)versioning_metadata,
                         (unsigned int)td_metadata,
                         &ranges[range_count],
                         num_blocks);

        if (free_range_ret == NULL)
        {
            tle_print("FAILED TO FIND FREE ENTRY!\n");
            write_fail_stage = "find_free_range_null";
            goto write_fail;
        }

        unsigned int first_md_block = ranges[range_count].pba / METADATA_ENTRIES_PER_BLOCK;
        unsigned int last_md_block = (ranges[range_count].pba + ranges[range_count].num_blocks - 1) / METADATA_ENTRIES_PER_BLOCK;
        for (unsigned int md_block = first_md_block; md_block <= last_md_block && versioning_metadata; ++md_block)
        {
            if (!md_block_already_queued(touched_md_blocks, touched_md_count, md_block))
            {
                if (touched_md_count >= MAX_MD_BLOCKS_IN_HEADER)
                {
                    tle_print("TOO MANY MD BLOCKS WERE FOUND IN WRITE REQ\n");
                    write_fail_stage = "too_many_md_blocks_initial";
                    goto write_fail;
                }
                touched_md_blocks[touched_md_count++] = md_block;
            }

            if (md_block == UINT32_MAX)
            {
                break;
            }
        }

        if (free_range_ret->tdmd_found)
        {
            if (!td_metadata)
            {
                free(free_range_ret);
                write_fail_stage = "unexpected_tdmd_found_td_disabled";
                goto write_fail;
            }
            if (set_pointer_and_reset_tdmd(0) != 0) {
                free(free_range_ret);
                tle_print("failed to reset hdmd");
                write_fail_stage = "set_pointer_reset_hdmd_failed";
                goto write_fail;
            }
            memcpy(&td_md_block_local, td_md_block, sizeof(TDMetadataLogBlock));
            // tle_print1("next:", td_md_block_local.pointer_next);
            hd_offset = cur_lba_offset;
            tdmd_tie_breaker = ranges[range_count].pba;
            // tle_print3("hd block, offset", ranges[range_count].pba, hd_offset, 0);
            range_count++;
            free(free_range_ret);
            continue;
        }

        if (free_range_ret->versioning_found)
        {
            if (set_pointer_and_reset_vmd() != 0) {
                free(free_range_ret);
                write_fail_stage = "set_pointer_reset_vmd_failed";
                goto write_fail;
            }
            memcpy(&version_md_block_local, l2p_block, sizeof(L2PBlock));
            version_offset = cur_lba_offset;
            vmd_tie_breaker = ranges[range_count].pba;
            // tle_print3("version block, offset", ranges[range_count].pba, version_offset, 0);
            range_count++;
            free(free_range_ret);
            continue;
        }
        free(free_range_ret);

        num_blocks -= ranges[range_count].num_blocks;
        cur_lba_offset += ranges[range_count].num_blocks;
        range_count++;
    }

    if (num_blocks < 0)
    {
        tle_print1("num blocks under: ", num_blocks);
        write_fail_stage = "num_blocks_underflow";
        goto write_fail;
    }
    range_count = merge_ranges(ranges, range_count); // merge ranges. this happens rarely, but simple to do.

    if (versioning_metadata && td_metadata && hd_offset >= 0)
    {
        // If this write carries an HD metadata log block, checker-side
        // ComputeLogUpdates may need metadata blocks referenced by that log,
        // not only the metadata blocks touched by data ranges.
        add_tdlog_referenced_md_blocks(&td_md_block_local, touched_md_blocks, &touched_md_count);
    }

    header.num_md_blocks = 0;
    if (versioning_metadata)
    {
        if (touched_md_count > 0)
        {
            // Optimized policy: never resend metadata blocks that are believed
            // resident in checker cache.
            for (unsigned int i = 0; i < touched_md_count; ++i)
            {
                unsigned int md = touched_md_blocks[i];
                if (!md_cache_membership[md])
                {
                    md_blocks[header.num_md_blocks++] = md;
                }
            }
        }
    }

    header.num_data_ranges = range_count;

    if (header.num_md_blocks > MAX_MD_BLOCKS_IN_HEADER)
    {
        tle_print("TOO MANY MD BLOCKS WERE FOUND IN WRITE REQ\n");
        write_fail_stage = "too_many_md_blocks_postmerge";
        goto write_fail;
    }

    // Prepare the message buffer layout
    // Header first
    memcpy(buffer_head, &header, sizeof(header));
    buffer_head = msg_buffer + sizeof(header);
    // tle_print("2");

    // Ranges next
    memcpy(buffer_head, ranges, sizeof(DataRange) * range_count);
    buffer_head += sizeof(DataRange) * range_count;

    // Metadata blocks
    for (int i = 0; i < header.num_md_blocks; ++i)
    {
        memcpy(buffer_head, &md_cache[md_blocks[i]], sizeof(CachedTDMetadataBlock));
        buffer_head += sizeof(CachedTDMetadataBlock);
    }
    // tle_print("3");

    // Write buffer (actual block data)
    if (version_offset >= 0 && hd_offset < 0)
    {
        memcpy(buffer_head, write_buffer, version_offset * BLOCK_SIZE);
        buffer_head += version_offset * BLOCK_SIZE;

        memcpy(buffer_head, &version_md_block_local, sizeof(version_md_block_local));
        buffer_head += sizeof(version_md_block_local);

         memcpy(buffer_head,
             write_buffer + version_offset * BLOCK_SIZE,
             (num_blocks_const - version_offset) * BLOCK_SIZE);
         buffer_head += (num_blocks_const - version_offset) * BLOCK_SIZE;
    }
    else if (version_offset < 0 && hd_offset >= 0)
    {
        memcpy(buffer_head, write_buffer, hd_offset * BLOCK_SIZE);
        buffer_head += hd_offset * BLOCK_SIZE;

        memcpy(buffer_head, &td_md_block_local, sizeof(td_md_block_local));
        buffer_head += sizeof(td_md_block_local);

         memcpy(buffer_head,
             write_buffer + hd_offset * BLOCK_SIZE,
             (num_blocks_const - hd_offset) * BLOCK_SIZE);
         buffer_head += (num_blocks_const - hd_offset) * BLOCK_SIZE;
    }
    else if (version_offset == hd_offset && version_offset > 0)
    {
        memcpy(buffer_head, write_buffer, version_offset * BLOCK_SIZE);
        buffer_head += version_offset * BLOCK_SIZE;

        if (tdmd_tie_breaker < vmd_tie_breaker) {
            memcpy(buffer_head, &td_md_block_local, sizeof(td_md_block_local));
            buffer_head += sizeof(td_md_block_local);

            memcpy(buffer_head, &version_md_block_local, sizeof(version_md_block_local));
            buffer_head += sizeof(version_md_block_local);
        }
        else if (tdmd_tie_breaker > vmd_tie_breaker) {


            memcpy(buffer_head, &td_md_block_local, sizeof(td_md_block_local));
            buffer_head += sizeof(td_md_block_local);

            memcpy(buffer_head, &version_md_block_local, sizeof(version_md_block_local));
            buffer_head += sizeof(version_md_block_local);
        }
        else {
            tle_print("tie break failed!\n");
            write_fail_stage = "tie_break_failed";
            goto write_fail;
        }

         memcpy(buffer_head, write_buffer + version_offset * BLOCK_SIZE,
             (num_blocks_const - version_offset) * BLOCK_SIZE);
         buffer_head += (num_blocks_const - version_offset) * BLOCK_SIZE;
    }
    else if (version_offset >= 0 && hd_offset >= 0)
    {
        // tle_print3("vo hdo", version_offset, hd_offset, 0);
        int first_offset, second_offset;
        unsigned int first_metadata_size, second_metadata_size;
        const void *first_metadata;
        const void *second_metadata;

        // Choose which metadata comes first
        if (version_offset < hd_offset)
        {
            first_offset = version_offset;
            first_metadata = &version_md_block_local;
            first_metadata_size = sizeof(version_md_block_local);

            second_offset = hd_offset;
            second_metadata = &td_md_block_local;
            second_metadata_size = sizeof(td_md_block_local);
        }
        else
        {
            first_offset = hd_offset;
            first_metadata = &td_md_block_local;
            first_metadata_size = sizeof(td_md_block_local);

            second_offset = version_offset;
            second_metadata = &version_md_block_local;
            second_metadata_size = sizeof(version_md_block_local);
        }

        // Copy up to the first metadata
        memcpy(buffer_head, write_buffer, first_offset * BLOCK_SIZE);
        buffer_head += first_offset * BLOCK_SIZE;

        // Insert the first metadata block
        memcpy(buffer_head, first_metadata, first_metadata_size);
        buffer_head += first_metadata_size;

         // Copy from first_offset up to second_offset
        memcpy(buffer_head,
             write_buffer + first_offset * BLOCK_SIZE,
             (second_offset - first_offset) * BLOCK_SIZE);
         buffer_head += (second_offset - first_offset) * BLOCK_SIZE;

        // Insert the second metadata block
        memcpy(buffer_head, second_metadata, second_metadata_size);
        buffer_head += second_metadata_size;

         // Copy the remainder from second_offset onward
        memcpy(buffer_head,
             write_buffer + second_offset * BLOCK_SIZE,
             (num_blocks_const - second_offset) * BLOCK_SIZE);
         buffer_head += (num_blocks_const - second_offset) * BLOCK_SIZE;
    }
    else
    {
        memcpy(buffer_head, write_buffer, write_buffer_size);
        buffer_head += write_buffer_size;
    }

    msg_len = (size_t)(buffer_head - msg_buffer);

write_send_retry:
    // payload_size is the bytes after the fixed-size header.
    header.payload_size = (uint32_t)(msg_len - sizeof(header));
    memcpy(msg_buffer, &header, sizeof(header));

    // Send message; receive confirmation
    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, msg_buffer, msg_len, conn_fd);
    int rval = (int)gk_recv(&success, sizeof(success));

    if (rval != sizeof(success))
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "write RVAL is %d, size is %ld\n", rval, sizeof(success));
        fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
        fclose(fptr);
        write_fail_stage = "write_recv_short";
        goto write_fail;
    }

    if (success == CHECKER_WRITE_DENIED)
    {
        log_write_rejection_context(write_buffer_offset, write_buffer_size, &header, ranges, range_count, md_blocks, success);
        tle_print("checker rejected write with WRITE_DENIED (255)");
        write_fail_stage = "checker_write_denied";
        goto write_fail;
    }

    if (success == CHECKER_FRESHNESS_REJECT)
    {
        log_write_rejection_context(write_buffer_offset, write_buffer_size, &header, ranges, range_count, md_blocks, success);
        tle_print("checker rejected write with FRESHNESS_REJECT (254)");
        write_fail_stage = "checker_freshness_reject";
        goto write_fail;
    }

    for (unsigned int i = 0; i < header.num_md_blocks; ++i)
    {
        note_md_membership_update(md_blocks[i],
                                  1,
                                  MEMBERSHIP_REASON_DEVICE_WRITE_SENT,
                                  "device_write",
                                  ranges[0].pba,
                                  i);
    }

    // Checker has said that we should evict n blocks from the cache.
    if (success)
    {
        if (success > MAX_MD_BLOCKS_IN_HEADER) {
            tle_print1("Too many blocks evicted: ", (unsigned int)success);
            write_fail_stage = "too_many_evicted_blocks";
            goto write_fail;
        }
        size_t evict_bytes = sizeof(CachedTDMetadataBlock) * success;
        CachedTDMetadataBlock *evict_buffer = malloc(evict_bytes);
        if (!evict_buffer)
        {
            tle_print("failed to allocate evict buffer");
            write_fail_stage = "evict_alloc_failed";
            goto write_fail;
        }
        int rval = (int)gk_recv(evict_buffer, evict_bytes);
        if (rval != (int)evict_bytes)
        {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "write evict RVAL is %d, expected is %zu, success is %u\n", rval, evict_bytes, (unsigned int)success);
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
            free(evict_buffer);
            write_fail_stage = "evict_recv_short";
            goto write_fail;
        }
        CachedTDMetadataBlock block;
        for (int i = 0; i < success; ++i)
        {
            memcpy(&block, &evict_buffer[i], sizeof(CachedTDMetadataBlock));
            if (!hash_is_all_ff(block.hash) &&
                block.idx < TOTAL_NUM_METADATA_BLOCKS) {
                md_cache[block.idx] = block;
                note_md_membership_update(block.idx,
                                          0,
                                          MEMBERSHIP_REASON_DEVICE_WRITE_EVICT,
                                          "device_write",
                                          ranges[0].pba,
                                          (unsigned int)success);
            }
        }
        free(evict_buffer);
        success = 0;
    }
    // tle_print("write5");
    return success;

write_fail:
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        if (fptr)
        {
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr,
                    "device_write fail stage=%s lba=%u write_buffer_offset=%llu write_buffer_size=%u num_blocks_const=%d range_count=%u header_ranges=%u header_md=%u payload=%u msg_len=%zu version_offset=%d hd_offset=%d\n",
                    write_fail_stage,
                    logical_block_address,
                    (unsigned long long)write_buffer_offset,
                    write_buffer_size,
                    num_blocks_const,
                    range_count,
                    header.num_data_ranges,
                    (unsigned int)header.num_md_blocks,
                    (unsigned int)header.payload_size,
                    msg_len,
                    version_offset,
                    hd_offset);
            fclose(fptr);
        }
    }
    return -1;
}

static int device_write_wrapper(const char *buffer, uint64_t offset, uint32_t size, struct bdus_ctx *ctx)
{
    if (read_only_mode)
    {
        return -EROFS;
    }

    pthread_mutex_lock(&write_lock);

    const uint32_t max_chunk_size = (uint32_t)MAX_MAPPING_COUNT * (uint32_t)BLOCK_SIZE;
    uint32_t remaining = size;
    uint64_t cur_offset = offset;
    const char *cur_buffer = buffer;
    int res = 0;

    while (remaining > 0)
    {
        uint32_t chunk_size = remaining;
        if (chunk_size > max_chunk_size)
        {
            chunk_size = max_chunk_size;
        }

        res = device_write(cur_buffer, cur_offset, chunk_size, ctx, false);
        if (res != 0)
        {
            break;
        }

        cur_offset += chunk_size;
        cur_buffer += chunk_size;
        remaining -= chunk_size;
    }

    pthread_mutex_unlock(&write_lock);
    return res;
}

static int device_flush(struct bdus_ctx *ctx)
{
    (void)ctx;

    if (read_only_mode)
    {
        return 0;
    }

    if (flush_pending_metadata() != 0) {
        tle_print("Flush was not complete");
        return -1;
    }

    return 0;
}

int terminate(struct bdus_ctx *ctx)
{
    (void)ctx;

    if (read_only_mode)
    {
        close(conn_fd);
        return 0;
    }

    if (flush_pending_metadata() != 0)
    {
       tle_print("Flush was not complete");
       return -1;
    }

    if (send_control_command(FINISH) != 0)
    {
        tle_print("Terminate was not complete");
        return -1;
    }

    close(conn_fd);
    return 0;
}

static const struct bdus_ops device_ops = {
    .read = device_read_wrapper,
    .write = device_write_wrapper,
    .flush = device_flush,
    .terminate = terminate,
};

static struct bdus_attrs device_attrs = {
    .size = LOGICAL_DISK_SIZE,
    .logical_block_size = BLOCK_SIZE,
};

/* -------------------------------------------------------------------------- */

void printHelp()
{
    char *help_str = "Usage: \n"
                     "  --timestamp <ts>\n"
                     "  --read-only\n"
                     "  --finish\n"
                     "  --mode <normal|versioning|barebones>\n"
                     "  --baseline\n"
                     "  --no-sec\n"
                     "  --verbose-cache\n"
                     "  --ipc         Use shared-memory IPC instead of TCP\n"
                     "  --no-gc-epoch  Disable GC-triggered cleanup and background security daemons\n"
                     "  --recovery\n"
                     "  --help\n";
    tle_print(help_str);
    printf("%s", help_str);
}

int main(int argc, char **argv)
{
    unsigned int recovery_timestamp = 0;

    // These are used with getopt_long()
    opterr = true; // Give us help with errors
    int choice;
    int option_index = 0;
    // unsigned int dont_daemonize = 0;

    struct option long_options[] =
        {
            {"timestamp", required_argument, NULL, 's'},
            {"read-only", no_argument, NULL, 'R'},
            {"finish", no_argument, NULL, 'f'},
            {"mode", required_argument, NULL, 'm'},
            {"baseline", no_argument, NULL, 'b'},
            {"no-sec", no_argument, NULL, 'n'},
            {"verbose-cache", no_argument, NULL, 'v'},
                {"ipc", no_argument, NULL, 'i'},
            {"no-gc-epoch", no_argument, NULL, 'g'},
            {"recovery", no_argument, NULL, 'r'},
            {"foreground", no_argument, NULL, 'd'},
            {"help", no_argument, NULL, 'h'},
            {NULL, 0, NULL, '\0'}};

            while ((choice = getopt_long(argc, argv, "s:Rfm:bnvigrdh", long_options,
                                 &option_index)) != -1)
    {
        switch (choice)
        {
        case 'R':
            read_only_mode = 1;
            break;

        case 's':
            recovery_timestamp = atoi(optarg);
            break;

        case 'f':
            finish = 1;
            break;

        case 'm':
            if (parse_driver_mode(optarg, &driver_mode) != 0)
            {
                fprintf(stderr, "Invalid mode '%s'. Expected one of: normal, versioning, barebones\n", optarg);
                exit(1);
            }
            break;

        case 'b':
            driver_mode = MODE_BAREBONES;
            no_sec = 1;
            break;

        case 'n':
            no_sec = 1;
            break;

        case 'v':
            verbose_cache_log = 1;
            break;

        case 'i':
            g_use_ipc = 1;
            break;

        case 'g':
            no_gc_epoch = 1;
            no_sec = 1;
            do_gc = 0;
            break;

        case 'r':
            recovery = 1;
            break;

        case 'd':
            device_attrs.dont_daemonize = 1;
            break;

        case 'h':
            printHelp();
            exit(0);

        default:
            printf("Error invalid option, use --help to see command line args");
            exit(1);
        }
    }

    if (g_use_ipc)
    {
        ipc_transport_init_client();
    }

    init_driver(recovery_timestamp);

    if (recovery)
    {
        // pass
    }
    else
    {
        void *buffer = NULL;
        bool success = bdus_run(&device_ops, &device_attrs, buffer);

        if (!success)
        {
            fprintf(stderr, "Error: %s\n", bdus_get_error_message());
        }

        return success ? 0 : 1;
    }

    if (finish)
    {
        // terminate();
    }

    return 0;
}

/* -------------------------------------------------------------------------- */
