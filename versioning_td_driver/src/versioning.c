#include "versioning.h"
#include "khash.h"
#include <unistd.h>
#include <time.h>
#include <math.h>

struct timespec diff_timespec(const struct timespec *time1,
                              const struct timespec *time0)
{
    assert(time1);
    assert(time0);
    struct timespec diff = {.tv_sec = time1->tv_sec - time0->tv_sec, //
                            .tv_nsec = time1->tv_nsec - time0->tv_nsec};
    if (diff.tv_nsec < 0)
    {
        diff.tv_nsec += 1000000000; // nsec/sec
        diff.tv_sec--;
    }
    return diff;
}

BlockEntryList *freelist = NULL;
BlockEntryList *gc_list = NULL;
BlockEntryList *tobe_freelist = NULL;

CachedTDMetadataBlock md_cache[TOTAL_NUM_METADATA_BLOCKS];
uint8_t md_cache_membership[TOTAL_NUM_METADATA_BLOCKS];

L2PBlock *l2p_block = NULL;
TDMetadataLogBlock *td_md_block = NULL;
// Log pointers will be determined during recovery/init instead of hard-coded
int current_vmd_block = -1;
int current_tdmd_block = -1;
int map_idx = 0;
int tdmd_idx = 0;
int current_seed = 0;
int leftover_vmd_block = -1;
int map_dirty = 0;
int tdmd_dirty = 0;
int persisted_tdmd_log_head = -1;
int persisted_tdmd_log_tail = -1;

// map logical index to physical index (logical block id (int) to physical block (BlockEntry struct))
BlockEntry **l2pmap = NULL;
unsigned int *p2lmap = NULL;
Segment **segment_list = NULL;
float *segment_p_list = NULL;
char *mark_free_blocks = NULL;
int conn_fd = -1;
int do_gc = 1;
int do_sync = 1;
int driver_mode = MODE_NORMAL;
int versioning_metadata = 1;
int td_metadata = 1;
int epoch_mode = 0;
int verbose_cache_log = 0;
int sync_count = 0;
int freelist_size = 0;

// Temporary bounded fix for P2: apply a constant keep duration to write-path metadata.
static const unsigned int WRITE_KEEP_DURATION_SECS = DEFAULT_KEEP_DURATION;
static const uint8_t CHECKER_WRITE_DENIED = 255;
static const uint8_t CHECKER_FRESHNESS_REJECT = 254;

// Diagnostics for timestamp-based recovery filtering.
static unsigned long recovery_seen_entries = 0;
static unsigned long recovery_invalid_sentinel_entries = 0;
static unsigned long recovery_invalid_bounds_entries = 0;
static unsigned long recovery_candidate_entries = 0;
static unsigned long recovery_skipped_newer_entries = 0;
static unsigned long recovery_skipped_uninitialized_entries = 0;
static unsigned long recovery_applied_entries = 0;
static unsigned int recovery_min_time_written = UINT32_MAX;
static unsigned int recovery_max_time_written = 0;
static unsigned int recovery_min_applied_time_written = UINT32_MAX;
static unsigned int recovery_max_applied_time_written = 0;
static unsigned int recovery_sample_logs_remaining = 0;
static uint8_t collect_tdlog_needed_md_indices(const TDMetadataLogBlock *hdlog, uint32_t out_idx[MAX_MD_BLOCKS_IN_HEADER]);
static unsigned int mdblock_checksum(const CachedTDMetadataBlock *block);
#ifdef NO_NETWORK
#ifndef VERSIONING_READ_ONLY_MODE_DEFINED
#define VERSIONING_READ_ONLY_MODE_DEFINED
int read_only_mode = 0;
#endif
#else
extern int read_only_mode;
#endif

bool hash_is_all_ff(const char hash[32])
{
    for (size_t i = 0; i < 32; ++i)
    {
        if ((uint8_t)hash[i] != 0xFF)
        {
            return false;
        }
    }
    return true;
}

static void reset_recovery_diagnostics(void)
{
    recovery_seen_entries = 0;
    recovery_invalid_sentinel_entries = 0;
    recovery_invalid_bounds_entries = 0;
    recovery_candidate_entries = 0;
    recovery_skipped_newer_entries = 0;
    recovery_skipped_uninitialized_entries = 0;
    recovery_applied_entries = 0;
    recovery_min_time_written = UINT32_MAX;
    recovery_max_time_written = 0;
    recovery_min_applied_time_written = UINT32_MAX;
    recovery_max_applied_time_written = 0;
    recovery_sample_logs_remaining = 8;
}

static void log_recovery_diagnostics(unsigned int recovery_timestamp)
{
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }

    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(
        fptr,
        "recovery summary ts=%u seen=%lu invalid_sentinel=%lu invalid_bounds=%lu candidates=%lu skipped_newer=%lu skipped_uninitialized=%lu applied=%lu tw_min=%u tw_max=%u applied_tw_min=%u applied_tw_max=%u\n",
        recovery_timestamp,
        recovery_seen_entries,
        recovery_invalid_sentinel_entries,
        recovery_invalid_bounds_entries,
        recovery_candidate_entries,
        recovery_skipped_newer_entries,
        recovery_skipped_uninitialized_entries,
        recovery_applied_entries,
        (recovery_min_time_written == UINT32_MAX ? 0 : recovery_min_time_written),
        recovery_max_time_written,
        (recovery_min_applied_time_written == UINT32_MAX ? 0 : recovery_min_applied_time_written),
        recovery_max_applied_time_written);
    fclose(fptr);
}

static void log_recovery_metadata_sample(unsigned int range_pba,
                                         MetadataEntry metadata_entry,
                                         const L2PBlock *block,
                                         unsigned int recovery_timestamp)
{
    if (recovery_sample_logs_remaining == 0)
    {
        return;
    }

    unsigned int first_lba = UINT32_MAX;
    unsigned int first_pba = UINT32_MAX;
    unsigned int valid_entries = 0;
    for (int i = 0; i < LENGTH_VERSION_LOG_BLOCK; ++i)
    {
        L2PEntry entry = block->map[i];
        if (entry.logical_block_address == UINT32_MAX || entry.physical_block_address == UINT32_MAX)
        {
            continue;
        }
        if (entry.physical_block_address >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            continue;
        }
        if (entry.logical_block_address >= (unsigned int)TOTAL_LOGICAL_NUM_BLOCKS)
        {
            continue;
        }
        if (first_lba == UINT32_MAX)
        {
            first_lba = entry.logical_block_address;
            first_pba = entry.physical_block_address;
        }
        valid_entries++;
    }

    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }

    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(
        fptr,
        "recovery sample range_pba=%u md_idx=%u md_offset=%u keep=%u time=%u ts=%u valid_entries=%u first_lba=%u first_pba=%u next_ptr=%u seed=%u\n",
        range_pba,
        (unsigned int)(range_pba / METADATA_ENTRIES_PER_BLOCK),
        (unsigned int)(range_pba % METADATA_ENTRIES_PER_BLOCK),
        metadata_entry.keep_duration,
        metadata_entry.time_written,
        recovery_timestamp,
        valid_entries,
        first_lba,
        first_pba,
        block->ptr,
        block->seed);
    fclose(fptr);
    recovery_sample_logs_remaining--;
}

static void log_metadata_reject_context(const char *op,
                                        uint8_t status,
                                        unsigned int range_pba,
                                        unsigned int md_idx)
{
    unsigned int offset = range_pba % METADATA_ENTRIES_PER_BLOCK;
    MetadataEntry denied_entry = md_cache[md_idx].mdblock.arr[offset];
    unsigned int current_timestamp = (unsigned int)(__rdtsc() >> 32);

    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (!fptr)
    {
        return;
    }

    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(fptr,
            "metadata reject op=%s status=%u range_pba=%u md_idx=%u current_vmd=%u current_tdmd=%u map_idx=%d tdmd_idx=%d map_dirty=%d tdmd_dirty=%d\n",
            op,
            (unsigned int)status,
            range_pba,
            md_idx,
            current_vmd_block,
            current_tdmd_block,
            map_idx,
            tdmd_idx,
            map_dirty,
            tdmd_dirty);
    fprintf(fptr,
            "metadata reject entry offset=%u keep_duration=%u time_written=%u current_timestamp=%u\n",
            offset,
            denied_entry.keep_duration,
            denied_entry.time_written,
            current_timestamp);
    fclose(fptr);
}

void note_md_membership_update(unsigned int idx,
                               uint8_t new_value,
                               MembershipReason reason,
                               const char *op,
                               unsigned int range_pba,
                               unsigned int aux)
{
    if (idx >= TOTAL_NUM_METADATA_BLOCKS)
    {
        return;
    }

    md_cache_membership[idx] = new_value;
    (void)reason;
    (void)op;
    (void)range_pba;
    (void)aux;
}

static void fail_metadata_reject_no_rebuild(const char *op,
                                            uint8_t status,
                                            unsigned int range_pba,
                                            unsigned int md_idx)
{
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (fptr)
    {
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr,
                "fatal metadata reject op=%s status=%u range_pba=%u md_idx=%u action=fail_no_cache_rebuild\n",
                op,
                (unsigned int)status,
                range_pba,
                md_idx);
        fclose(fptr);
    }

    if (status == CHECKER_WRITE_DENIED)
    {
        tle_print("fatal: checker rejected metadata write with WRITE_DENIED (255); cache rebuild retry disabled");
    }
    else if (status == CHECKER_FRESHNESS_REJECT)
    {
        tle_print("fatal: checker rejected metadata write with FRESHNESS_REJECT (254); cache rebuild retry disabled");
    }
    else
    {
        tle_print1("fatal: checker rejected metadata write with unexpected status", (unsigned int)status);
    }

    exit(1);
}

static int read_tdlog_block(unsigned int pba, TDMetadataLogBlock *block)
{
    char msg_buffer[sizeof(unsigned int) + MAX_MAPPING_SIZE];
    char *buffer_head = msg_buffer;
    MessageHeader header = {
        .payload_size = 0,
        .num_data_ranges = 1,
        .num_md_blocks = 0,
        .disk_cmd = READ,
    };
    DataRange range = {.pba = pba, .num_blocks = 1};

    memcpy(buffer_head, &header, sizeof(header));
    buffer_head += sizeof(header);
    memcpy(buffer_head, &range, sizeof(range));
    buffer_head += sizeof(range);

    header.payload_size = (uint32_t)((size_t)(buffer_head - msg_buffer) - sizeof(header));
    memcpy(msg_buffer, &header, sizeof(header));

    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, msg_buffer, buffer_head - msg_buffer, conn_fd);
    int rval = (int)gk_recv(block, sizeof(*block));
    if (rval != (int)sizeof(*block))
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        if (fptr)
        {
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "hdlog scan RVAL is %d, size is %zu, pba=%u\n", rval, sizeof(*block), pba);
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
        }
        return -1;
    }

    return 0;
}

static void mark_hdlog_chain_reserved(void)
{
    if (persisted_tdmd_log_head < 0 || persisted_tdmd_log_tail < 0)
    {
        return;
    }

    unsigned int log_head = (unsigned int)persisted_tdmd_log_head;
    unsigned int log_tail = (unsigned int)persisted_tdmd_log_tail;
    unsigned int curr = log_head;
    unsigned int reserved_blocks = 0;
    char *visited = calloc(TOTAL_PHYSICAL_NUM_BLOCKS, sizeof(char));
    if (!visited)
    {
        return;
    }

    // log_tail is the next HDMD slot; reserve it as well so it cannot be used for data.
    if (log_tail < TOTAL_PHYSICAL_NUM_BLOCKS)
    {
        mark_free_blocks[log_tail] = 0;
    }

    while (curr < TOTAL_PHYSICAL_NUM_BLOCKS && curr != log_tail)
    {
        if (visited[curr])
        {
            break;
        }
        visited[curr] = 1;
        mark_free_blocks[curr] = 0;
        reserved_blocks++;

        TDMetadataLogBlock log_block;
        if (read_tdlog_block(curr, &log_block) != 0)
        {
            break;
        }

        if (log_block.pointer_next >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            break;
        }

        curr = log_block.pointer_next;
    }

    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    if (fptr)
    {
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr,
                "hdlog reserve summary head=%u tail=%u reserved_committed=%u stopped_at=%u\n",
                log_head,
                log_tail,
                reserved_blocks,
                curr);
        fclose(fptr);
    }

    free(visited);
}

BlockEntry *free_block_queue[MAX_MAPPING_COUNT];
pthread_mutex_t gc_lock;
pthread_mutex_t l2p_lock;
pthread_mutex_t vmd_lock;
pthread_mutex_t write_lock;
pthread_mutex_t tdmd_lock;
pthread_mutex_t segment_lock;
pthread_mutex_t freelist_lock;
pthread_mutex_t tobe_freelist_lock;
pthread_mutex_t epoch_set_lock;

KHASH_MAP_INIT_INT(epoch_map, int)
khash_t(epoch_map) * hi;

void versioning_init()
{
    hi = kh_init(epoch_map);

    freelist = (BlockEntryList *)malloc(sizeof(BlockEntryList));
    freelist->head = NULL;
    freelist->tail = NULL;
    l2pmap = malloc(sizeof(struct BlockEntry *) * TOTAL_LOGICAL_NUM_BLOCKS);
    p2lmap = malloc(sizeof(unsigned int) * TOTAL_PHYSICAL_NUM_BLOCKS);
    segment_list = malloc(sizeof(struct Segment *) * TOTAL_NUM_SEGMENTS);
    segment_p_list = malloc(sizeof(float) * TOTAL_NUM_SEGMENTS);
    tobe_freelist = (BlockEntryList *)malloc(sizeof(BlockEntryList));
    tobe_freelist->head = NULL;
    tobe_freelist->tail = NULL;
    gc_list = (BlockEntryList *)malloc(sizeof(BlockEntryList));
    gc_list->head = NULL;
    gc_list->tail = NULL;
    l2p_block = malloc(sizeof(L2PBlock));
    td_md_block = malloc(sizeof(TDMetadataLogBlock));
    mark_free_blocks = malloc(sizeof(char) * TOTAL_PHYSICAL_NUM_BLOCKS);

    for (int i = 0; i < TOTAL_LOGICAL_NUM_BLOCKS; i++)
    {
        l2pmap[i] = NULL;
    }

    for (int i = 0; i < TOTAL_PHYSICAL_NUM_BLOCKS; i++)
    {
        p2lmap[i] = UINT32_MAX;
        mark_free_blocks[i] = 1;
    }

    for (int i = 0; i < TOTAL_NUM_SEGMENTS; ++i)
    {
        segment_list[i] = malloc(sizeof(struct Segment));
        segment_list[i]->free_blocks = 0;
        segment_list[i]->hot_bit = 0;
    }

    for (int i = 0; i < TOTAL_NUM_METADATA_BLOCKS; ++i)
    {
        note_md_membership_update((unsigned int)i,
                                  0,
                                  MEMBERSHIP_REASON_INIT_RESET,
                                  "versioning_init",
                                  0,
                                  0);
    }

    pthread_mutex_init(&gc_lock, NULL);
    pthread_mutex_init(&l2p_lock, NULL);
    pthread_mutex_init(&vmd_lock, NULL);
    pthread_mutex_init(&write_lock, NULL);
    pthread_mutex_init(&tdmd_lock, NULL);
    pthread_mutex_init(&segment_lock, NULL);
    pthread_mutex_init(&freelist_lock, NULL);
    pthread_mutex_init(&tobe_freelist_lock, NULL);
    pthread_mutex_init(&epoch_set_lock, NULL);
}

void enqueue_list(BlockEntry *entry, BlockEntryList *list, pthread_mutex_t *lock)
{
    pthread_mutex_lock(lock);
    if (!list->head)
    {
        list->head = entry;
    }
    if (list->tail)
    {
        list->tail->next = entry;
    }
    list->tail = entry;
    if (list == freelist)
    {
        freelist_size++;
    }
    pthread_mutex_unlock(lock);
}

static void mark_reserved_block(BlockEntry *entry)
{
    if (read_only_mode)
    {
        return;
    }

    pthread_mutex_lock(&segment_lock);
    segment_list[entry->physical_block_id / BLOCKS_PER_SEGMENT]->free_blocks--;
    segment_list[entry->physical_block_id / BLOCKS_PER_SEGMENT]->hot_bit = 1;
    pthread_mutex_unlock(&segment_lock);
}

void release_reserved_block(BlockEntry *reserved_entry)
{
    if (!reserved_entry)
    {
        return;
    }

    reserved_entry->next = NULL;
    reserved_entry->keep_duration = 0;
    reserved_entry->time_written = 0;
    enqueue_list(reserved_entry, freelist, &freelist_lock);

    pthread_mutex_lock(&segment_lock);
    segment_list[reserved_entry->physical_block_id / BLOCKS_PER_SEGMENT]->free_blocks++;
    pthread_mutex_unlock(&segment_lock);
}

static int reserve_next_tdmd_block(int init, BlockEntry **reserved_entry)
{
    (void)init;

    // Keep HDMD placement tied to HD log payload capacity, not current PBA.
    // The HD log block has 1021 arr slots and one is self-reference, so using
    // a fixed offset keeps the next HDMD reservation roughly "after" the data
    // and avoids runaway growth from PBA-as-ordinal indexing.
    BlockEntry *next_hdmd = pop_nth_in_freelist(LENGTH_TD_LOG_BLOCK - 2);
    if (!next_hdmd)
    {
        FILE *reserve_fail_fptr = fopen("/tmp/timelockdriver.log", "a");
        if (reserve_fail_fptr) {
            setvbuf(reserve_fail_fptr, NULL, _IONBF, 0);
            fprintf(reserve_fail_fptr, "RESERVE_NEXT_HDMD_BLOCK_FAILED: pop_nth_in_freelist(LENGTH_TD_LOG_BLOCK-2=%u) returned NULL\n",
                    (unsigned int)(LENGTH_TD_LOG_BLOCK - 2));
            fclose(reserve_fail_fptr);
        }
        tle_print("failed to get next hdmd");
        return -1;
    }

    mark_reserved_block(next_hdmd);
    *reserved_entry = next_hdmd;
    // FILE *reserve_ok_fptr = fopen("/tmp/timelockdriver.log", "a");
    // if (reserve_ok_fptr) {
    //     setvbuf(reserve_ok_fptr, NULL, _IONBF, 0);
    //     fprintf(reserve_ok_fptr, "RESERVE_NEXT_HDMD_BLOCK_SUCCESS: got PBA=%u\n", next_hdmd->physical_block_id);
    //     fclose(reserve_ok_fptr);
    // }
    return 0;
}

static int reserve_next_vmd_block(BlockEntry **reserved_entry)
{
    BlockEntry *next_vmd = pop_nth_in_freelist(LENGTH_VERSION_LOG_BLOCK);
    if (!next_vmd)
    {
        tle_print("failed to get next vmd");
        return -1;
    }

    mark_reserved_block(next_vmd);
    *reserved_entry = next_vmd;
    return 0;
}

int prepare_tdmd_write(int init, TDMetadataLogBlock *prepared_block, BlockEntry **reserved_entry)
{
    if (reserve_next_tdmd_block(init, reserved_entry) != 0)
    {
        return -1;
    }

    pthread_mutex_lock(&tdmd_lock);
    memcpy(prepared_block, td_md_block, sizeof(*prepared_block));
    prepared_block->keep_duration = WRITE_KEEP_DURATION_SECS;
    prepared_block->current_time = (unsigned int)(__rdtsc() >> 32);
    prepared_block->pointer_next = (*reserved_entry)->physical_block_id;
    pthread_mutex_unlock(&tdmd_lock);
    return 0;
}

int prepare_vmd_write(L2PBlock *prepared_block, BlockEntry **reserved_entry)
{
    if (reserve_next_vmd_block(reserved_entry) != 0)
    {
        return -1;
    }

    pthread_mutex_lock(&vmd_lock);
    memcpy(prepared_block, l2p_block, sizeof(*prepared_block));
    prepared_block->ptr = (*reserved_entry)->physical_block_id;
    pthread_mutex_unlock(&vmd_lock);
    return 0;
}

void commit_tdmd_write(BlockEntry *reserved_entry, const TDMetadataLogBlock *prepared_block)
{
    if (!reserved_entry)
    {
        return;
    }

    pthread_mutex_lock(&tdmd_lock);
    memcpy(td_md_block, prepared_block, sizeof(*prepared_block));
    current_tdmd_block = reserved_entry->physical_block_id;
    tdmd_idx = 0;
    pthread_mutex_unlock(&tdmd_lock);

    free(reserved_entry);
}

void commit_vmd_write(BlockEntry *reserved_entry, const L2PBlock *prepared_block)
{
    if (!reserved_entry)
    {
        return;
    }

    pthread_mutex_lock(&vmd_lock);
    memcpy(l2p_block, prepared_block, sizeof(*prepared_block));
    current_vmd_block = reserved_entry->physical_block_id;
    map_idx = 0;
    pthread_mutex_unlock(&vmd_lock);

    free(reserved_entry);
}

void perform_gc()
{
    BlockEntry *entry = NULL;

    pthread_mutex_lock(&gc_lock);
    if (gc_list->head)
    {
        entry = gc_list->head;
        gc_list->head = entry->next;
        if (!gc_list->head)
        {
            gc_list->tail = NULL;
        }
        entry->next = NULL;
    }
    pthread_mutex_unlock(&gc_lock);

    if (!entry)
    {
        return;
    }

    pthread_mutex_lock(&write_lock);
    pthread_mutex_lock(&tdmd_lock);

    if (tdmd_idx == 0)
    {
        // Keep log self-reference semantics consistent with the write path.
        td_md_block->arr[tdmd_idx++] = current_tdmd_block;
    }

    bool log_full = false;
    if (tdmd_idx < LENGTH_TD_LOG_BLOCK)
    {
        td_md_block->arr[tdmd_idx++] = entry->physical_block_id;
        tdmd_dirty = 1;
        log_full = (tdmd_idx == LENGTH_TD_LOG_BLOCK);
    }

    pthread_mutex_unlock(&tdmd_lock);

    if (log_full)
    {
        send_hd_metadata();
    }
    else if (gc_list->head == NULL)
    {
        send_hd_metadata();
    }

    pthread_mutex_unlock(&write_lock);

    entry->time_written = (unsigned int)(__rdtsc() >> 32);
    entry->keep_duration = entry->time_written + DEFAULT_KEEP_DURATION;
    enqueue_list(entry, tobe_freelist, &tobe_freelist_lock);
}

static void epoch_timelock_physical_block(BlockEntry *entry)
{
    unsigned int now = (unsigned int)(__rdtsc() >> 32);
    entry->time_written = now;
    entry->keep_duration = now + DEFAULT_KEEP_DURATION;

    pthread_mutex_lock(&write_lock);
    pthread_mutex_lock(&tdmd_lock);

    if (tdmd_idx == 0)
    {
        td_md_block->arr[tdmd_idx++] = current_tdmd_block;
        if (leftover_vmd_block > 0)
        {
            td_md_block->arr[tdmd_idx++] = leftover_vmd_block;
            leftover_vmd_block = 0;
        }
    }

    if (tdmd_idx < LENGTH_TD_LOG_BLOCK)
    {
        td_md_block->arr[tdmd_idx++] = entry->physical_block_id;
        tdmd_dirty = 1;
    }

    bool log_full = (tdmd_idx == LENGTH_TD_LOG_BLOCK);
    pthread_mutex_unlock(&tdmd_lock);

    if (log_full)
    {
        send_hd_metadata();
    }
    pthread_mutex_unlock(&write_lock);
}

void flush_epoch_timelock_set()
{
    unsigned int current_timestamp = (unsigned int)(__rdtsc() >> 32);
    unsigned int count = kh_size(hi);
    unsigned int *lbas = NULL;
    unsigned int collected = 0;

    if (count > 0)
    {
        lbas = malloc(sizeof(unsigned int) * count);
        if (!lbas)
        {
            return;
        }
    }

    pthread_mutex_lock(&epoch_set_lock);
    for (khiter_t k = kh_begin(hi); k != kh_end(hi); ++k)
    {
        if (!kh_exist(hi, k))
        {
            continue;
        }
        lbas[collected++] = kh_key(hi, k);
    }

    for (unsigned int i = 0; i < collected; ++i)
    {
        khiter_t k = kh_get(epoch_map, hi, lbas[i]);
        if (k != kh_end(hi))
        {
            kh_del(epoch_map, hi, k);
        }
    }
    pthread_mutex_unlock(&epoch_set_lock);

    for (unsigned int i = 0; i < collected; ++i)
    {
        unsigned int lba = lbas[i];
        BlockEntry *entry = l2pmap[lba];
        if (!entry)
        {
            continue;
        }
        entry->time_written = current_timestamp;
        entry->keep_duration = current_timestamp + DEFAULT_KEEP_DURATION;
        epoch_timelock_physical_block(entry);
    }

    if (tdmd_dirty)
    {
        send_hd_metadata();
    }

    if (lbas)
    {
        free(lbas);
    }
}

void move_expired_to_free()
{
    unsigned int current_timestamp = (unsigned int)(__rdtsc() >> 32);
    pthread_mutex_lock(&tobe_freelist_lock);
    BlockEntry *entry = tobe_freelist->head;
    BlockEntry *prev = NULL;
    while (entry)
    {
        if (entry->keep_duration < current_timestamp)
        { // entry expired
            // if we are at the head of the list, move the head down
            if (entry == tobe_freelist->head)
            {
                tobe_freelist->head = entry->next;
            }
            else
            { // otherwise, make the prev point to the next so we can remove the entry
                prev->next = entry->next;
            }
            // tle_print1("moved expired entry", entry->physical_block_id);
            enqueue_list(entry, freelist, &freelist_lock);
            pthread_mutex_lock(&segment_lock);
            segment_list[entry->physical_block_id / BLOCKS_PER_SEGMENT]->free_blocks++;
            pthread_mutex_unlock(&segment_lock);

            BlockEntry *del = entry;
            entry = entry->next;
            del->next = NULL;
            continue;
        }

        prev = entry;
        entry = entry->next;
    }
    pthread_mutex_unlock(&tobe_freelist_lock);
}

BlockEntry *pop_top_of_freelist()
{
    // pthread_mutex_lock(&freelist_lock);
    BlockEntry *front_entry = freelist->head;
    if (!front_entry)
    {
        // Last ditch effort, check if we have any free blocks in the tobe free list!
        move_expired_to_free();
        front_entry = freelist->head;
        if (!front_entry)
        {
            tle_print("No free block found!\n");
            // pthread_mutex_unlock(&freelist_lock);
            return front_entry;
        }
    }

    // pop front entry off top of queue
    freelist->head = front_entry->next;
    front_entry->next = NULL;

    // If we detect that we are running out of free blocks, signal for GC but don't block here
    freelist_size--;
    if (do_gc && freelist_size < (TOTAL_PHYSICAL_NUM_BLOCKS / 10))
    {
        tle_print("low freelist, gc_daemon will handle GC");
    }
    return front_entry;
}

BlockEntry *pop_nth_in_freelist(unsigned int n)
{
    // tle_print1("n: ", n);
    if (n < 2)
    {
        tle_print("Not compatiable with n less than 2");
        return NULL;
    }
    BlockEntry *prev_entry = NULL;
    pthread_mutex_lock(&freelist_lock);
    BlockEntry *curr_entry = freelist->head;
    for (int i = 0; i < n; ++i)
    {
        if (curr_entry == NULL)
        {
            tle_print("Ran out of free bocks");
            pthread_mutex_unlock(&freelist_lock);
            return NULL;
        }
        // tle_print_long("pop", curr_entry);
        prev_entry = curr_entry;
        curr_entry = curr_entry->next;
    }
    // Check if we successfully found the nth element
    if (!curr_entry)
    {
        tle_print("List too short for requested index");
        pthread_mutex_unlock(&freelist_lock);
        return NULL;
    }
    // Remove nth entry from free queue
    // tle_print3("prev curr next", prev_entry->physical_block_id, curr_entry->physical_block_id, curr_entry->next->physical_block_id);
    prev_entry->next = curr_entry->next;
    curr_entry->next = NULL;
    pthread_mutex_unlock(&freelist_lock);

    // If we detect that we are running out of free blocks, signal for GC but don't block here
    freelist_size--;
    if (do_gc && freelist_size < (TOTAL_PHYSICAL_NUM_BLOCKS / 10))
    {
        tle_print("low freelist, gc_daemon will handle GC");
    }
    return curr_entry;
}

BlockEntry *peek_top_of_freelist()
{
    BlockEntry *front_entry = freelist->head;
    return front_entry;
}

RangeRet *find_free_range(unsigned int logical_block_address,
                          unsigned int versioning_metadata,
                          unsigned int td_metadata,
                          DataRange *range,
                          unsigned int num_blocks)
{
    RangeRet *rt_value = malloc(sizeof(RangeRet));
    rt_value->versioning_found = false;
    rt_value->tdmd_found = false;
    rt_value->epoch_reuse = false;
    range->num_blocks = 0;
    // move_expired_to_free();
    // if (map_idx == LENGTH_VERSION_LOG_BLOCK && tdmd_idx == LENGTH_TD_LOG_BLOCK) {
    //     tle_print3("", current_tdmd_block, current_vmd_block, 0);
    // }

    // Add the current version MD to the range
    if (td_metadata && tdmd_idx == LENGTH_TD_LOG_BLOCK)
    {
        // tle_print1("WRITING HDMD BLOCK", current_tdmd_block);
        range->pba = current_tdmd_block;
        range->num_blocks = 1;
        rt_value->tdmd_found = true;
        return rt_value;
    }

    // Add the current version MD to the range
    if (map_idx == LENGTH_VERSION_LOG_BLOCK)
    {
        // tle_print1("WRITING VERSION BLOCK", current_vmd_block);
        range->pba = current_vmd_block;
        range->num_blocks = 1;
        rt_value->versioning_found = true;
        return rt_value;
    }

    if (epoch_mode && num_blocks == 1)
    {
        bool in_epoch = false;
        pthread_mutex_lock(&epoch_set_lock);
        khiter_t k = kh_get(epoch_map, hi, logical_block_address);
        if (k != kh_end(hi))
        {
            in_epoch = true;
        }
        pthread_mutex_unlock(&epoch_set_lock);

        if (in_epoch)
        {
            pthread_mutex_lock(&l2p_lock);
            BlockEntry *existing_entry = l2pmap[logical_block_address];
            if (existing_entry)
            {
                range->pba = existing_entry->physical_block_id;
                range->num_blocks = 1;
                pthread_mutex_unlock(&l2p_lock);
                rt_value->epoch_reuse = true;
                return rt_value;
            }
            pthread_mutex_unlock(&l2p_lock);
        }
    }

    pthread_mutex_lock(&l2p_lock);
    pthread_mutex_lock(&freelist_lock);

    for (int i = 0; i < num_blocks; i++)
    {
        unsigned int lba_offset = logical_block_address + i;
        BlockEntry *peek = freelist->head;//peek_top_of_freelist();
        // tle_print_long("peek", peek);
        if (peek == NULL)
        {
            pthread_mutex_unlock(&l2p_lock);
            pthread_mutex_unlock(&freelist_lock);
            return NULL;
        }
        if (i == 0)
        {
            range->pba = peek->physical_block_id;
        }
        else if (peek->physical_block_id == (range->pba + range->num_blocks))
        {
        }
        else
        {
            pthread_mutex_unlock(&l2p_lock);
            pthread_mutex_unlock(&freelist_lock);
            return rt_value;
        }
        BlockEntry *front_entry = pop_top_of_freelist();
        if (front_entry != peek)
        {
            pthread_mutex_unlock(&l2p_lock);
            pthread_mutex_unlock(&freelist_lock);
            return NULL;
        }
        range->num_blocks++;
        // tle_print1("num blocks in range: ", range->num_blocks);

        // move old entry "to-be free list"
        BlockEntry *old_entry = l2pmap[lba_offset];
        if (old_entry)
        {
            p2lmap[old_entry->physical_block_id] = UINT32_MAX;
            enqueue_list(old_entry, gc_list, &gc_lock);
        }

        // update l2p mapping
        l2pmap[lba_offset] = front_entry;
        front_entry->keep_duration = WRITE_KEEP_DURATION_SECS; // Keep duration applied at write time

        // update p2l mapping for new entry
        p2lmap[front_entry->physical_block_id] = lba_offset;

        // update segment metadata
        pthread_mutex_lock(&segment_lock);
        segment_list[front_entry->physical_block_id / BLOCKS_PER_SEGMENT]->free_blocks--;
        segment_list[front_entry->physical_block_id / BLOCKS_PER_SEGMENT]->hot_bit = 1;
        pthread_mutex_unlock(&segment_lock);

        if (versioning_metadata && !rt_value->epoch_reuse)
        {
            khiter_t k;
            int ret;

            pthread_mutex_lock(&epoch_set_lock);
            k = kh_get(epoch_map, hi, lba_offset);
            if (k == kh_end(hi))
            {
                k = kh_put(epoch_map, hi, lba_offset, &ret);
                if (!ret)
                {
                    tle_print("error w epoch_map!!");
                    kh_del(epoch_map, hi, k);
                }
            }
            pthread_mutex_unlock(&epoch_set_lock);
            pthread_mutex_lock(&vmd_lock);
            if (td_metadata)
            {
                pthread_mutex_lock(&tdmd_lock);
                if (tdmd_idx == 0)
                {
                    // timelock the hd block itself!
                    td_md_block->arr[tdmd_idx++] = current_tdmd_block;
                    if (leftover_vmd_block > 0)
                    {
                        td_md_block->arr[tdmd_idx++] = leftover_vmd_block;
                        leftover_vmd_block = 0;
                    }
                }
            }

            l2p_block->map[map_idx].logical_block_address = lba_offset;
            l2p_block->map[map_idx++].physical_block_address = front_entry->physical_block_id;
            map_dirty = 1;
            if (td_metadata)
            {
                td_md_block->arr[tdmd_idx++] = front_entry->physical_block_id;
                tdmd_dirty = 1;
            }
            // map_idx = 0;
            // tdmd_idx = 0;
            // tle_print1("tdmd_idx", tdmd_idx);
            if (map_idx == LENGTH_VERSION_LOG_BLOCK || (td_metadata && tdmd_idx == LENGTH_TD_LOG_BLOCK))
            {
                if (td_metadata && map_idx == LENGTH_VERSION_LOG_BLOCK && tdmd_idx == LENGTH_TD_LOG_BLOCK)
                {
                    leftover_vmd_block = current_vmd_block;
                }
                else if (td_metadata && map_idx == LENGTH_VERSION_LOG_BLOCK)
                {
                    td_md_block->arr[tdmd_idx++] = current_vmd_block;
                    tdmd_dirty = 1;
                }
                pthread_mutex_unlock(&vmd_lock);
                if (td_metadata)
                {
                    pthread_mutex_unlock(&tdmd_lock);
                }
                pthread_mutex_unlock(&l2p_lock);
                pthread_mutex_unlock(&freelist_lock);
                return rt_value;
            }
            if (td_metadata)
            {
                pthread_mutex_unlock(&tdmd_lock);
            }
            pthread_mutex_unlock(&vmd_lock);
        }
    }

    pthread_mutex_unlock(&freelist_lock);
    pthread_mutex_unlock(&l2p_lock);

    // GC is handled by the gc_daemon thread, not in the foreground write path
    return rt_value;
}

int set_pointer_and_reset_tdmd(int init)
{
    BlockEntry *reserved_entry = NULL;
    TDMetadataLogBlock prepared_block;
    if (prepare_tdmd_write(init, &prepared_block, &reserved_entry) != 0)
    {
        return -1;
    }
    commit_tdmd_write(reserved_entry, &prepared_block);
    return 0;
}

int set_pointer_and_reset_vmd()
{
    BlockEntry *reserved_entry = NULL;
    L2PBlock prepared_block;
    if (prepare_vmd_write(&prepared_block, &reserved_entry) != 0)
    {
        return -1;
    }
    commit_vmd_write(reserved_entry, &prepared_block);
    return 0;
}

void send_hd_metadata()
{
    if (!tdmd_dirty)
    {
        return;
    }

#ifdef NO_NETWORK
    tdmd_idx = 0;
    tdmd_dirty = 0;
    return;
#endif

    FILE *pre_fptr = fopen("/tmp/timelockdriver.log", "a");
    if (pre_fptr) {
        setvbuf(pre_fptr, NULL, _IONBF, 0);
        fprintf(pre_fptr, "SEND_HD_METADATA_ENTRY: current_tdmd_block=%d tdmd_idx=%d tdmd_dirty=%d\n",
                current_tdmd_block, tdmd_idx, tdmd_dirty);
        fclose(pre_fptr);
    }

    pthread_mutex_lock(&tdmd_lock);
    tle_print("snd hd md\n");

    for (; tdmd_idx < LENGTH_TD_LOG_BLOCK; tdmd_idx++)
    {
        td_md_block->arr[tdmd_idx] = current_tdmd_block;
    }

    pthread_mutex_unlock(&tdmd_lock);

    uint8_t success;
    char msg_buffer[MAX_MSG_LENGTH];
    char *buffer_head;
    TDMetadataLogBlock td_md_block_local;
    BlockEntry *reserved_hdmd_entry;
    MessageHeader header;
    DataRange range;
    unsigned int md_idx;
    uint32_t needed_md_idx[MAX_MD_BLOCKS_IN_HEADER];
    uint32_t sent_md_idx[MAX_MD_BLOCKS_IN_HEADER];
    uint8_t needed_md_count;
    uint8_t sent_md_count;
    int rval;

    success = 255;
    buffer_head = msg_buffer;
    reserved_hdmd_entry = NULL;
    header = (MessageHeader){.num_data_ranges = 1, .num_md_blocks = 0, .disk_cmd = WRITE};
    range = (DataRange){.pba = current_tdmd_block, .num_blocks = 1};

    md_idx = (current_tdmd_block / METADATA_ENTRIES_PER_BLOCK);

    int prepare_result = prepare_tdmd_write(1, &td_md_block_local, &reserved_hdmd_entry);
    if (prepare_result != 0)
    {
        FILE *fail_fptr = fopen("/tmp/timelockdriver.log", "a");
        if (fail_fptr) {
            setvbuf(fail_fptr, NULL, _IONBF, 0);
            fprintf(fail_fptr, "SEND_HD_METADATA_EARLY_RETURN_BUG: prepare_tdmd_write failed! result=%d current_tdmd_block=%d tdmd_idx=%d tdmd_dirty=%d (NOT CLEARED!)\n",
                    prepare_result, current_tdmd_block, tdmd_idx, tdmd_dirty);
            fclose(fail_fptr);
        }
        return;
    }

    needed_md_count = collect_tdlog_needed_md_indices(&td_md_block_local, needed_md_idx);

    sent_md_count = 0;
    for (uint8_t i = 0; i < needed_md_count; ++i)
    {
        uint32_t idx = needed_md_idx[i];
        if (idx >= TOTAL_NUM_METADATA_BLOCKS)
        {
            continue;
        }

        if (sent_md_count >= MAX_MD_BLOCKS_IN_HEADER)
        {
            break;
        }
        if (md_cache_membership[idx])
        {
            continue;
        }
        sent_md_idx[sent_md_count++] = idx;
    }


    header.num_md_blocks = sent_md_count;

    // write header and ranges to message buffer
    memcpy(buffer_head, &header, sizeof(header));
    buffer_head += sizeof(header);

    memcpy(buffer_head, &range, sizeof(range));
    buffer_head += sizeof(range);

    for (uint8_t i = 0; i < sent_md_count; ++i)
    {
        uint32_t idx = sent_md_idx[i];
        memcpy(buffer_head, &md_cache[idx], sizeof(CachedTDMetadataBlock));
        buffer_head += sizeof(CachedTDMetadataBlock);
    }

    memcpy(buffer_head, &td_md_block_local, sizeof(TDMetadataBlock));
    buffer_head += sizeof(TDMetadataBlock);

    header.payload_size = (uint32_t)((size_t)(buffer_head - msg_buffer) - sizeof(header));
    memcpy(msg_buffer, &header, sizeof(header));

    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, msg_buffer, buffer_head - msg_buffer, conn_fd);
    rval = (int)gk_recv(&success, sizeof(success));

    if (rval != (int)sizeof(success))
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "write RVAL is %d, size is %zu, success is %d\n", rval, sizeof(success), success);
        fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
        fclose(fptr);
        exit(1);
    }

    if (success == CHECKER_WRITE_DENIED)
    {
        release_reserved_block(reserved_hdmd_entry);
        log_metadata_reject_context("send_hd_metadata", success, range.pba, md_idx);
        fail_metadata_reject_no_rebuild("send_hd_metadata", success, range.pba, md_idx);
    }

    if (success == CHECKER_FRESHNESS_REJECT)
    {
        release_reserved_block(reserved_hdmd_entry);
        log_metadata_reject_context("send_hd_metadata", success, range.pba, md_idx);
        fail_metadata_reject_no_rebuild("send_hd_metadata", success, range.pba, md_idx);
    }

    // Checker has said that we should evict n blocks from the cache.
    if (success)
    {
        if (success > MAX_MD_BLOCKS_IN_HEADER) {
            tle_print1("Too many blocks evicted: ", (unsigned int)success);
        }
        uint8_t *evict_buffer = malloc(sizeof(CachedTDMetadataBlock) * success);
        size_t evict_bytes = sizeof(CachedTDMetadataBlock) * success;
        rval = (int)gk_recv(evict_buffer, evict_bytes);
        if (rval != (int)evict_bytes)
        {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "evict RVAL is %d, expected is %zu, success is %u\n", rval, evict_bytes, (unsigned int)success);
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
            free(evict_buffer);
            exit(1);
        }
        CachedTDMetadataBlock block;
        for (int i = 0; i < success; ++i)
        {
            block = ((CachedTDMetadataBlock *)evict_buffer)[i];
            tle_print3("evicted snd md: ", block.counter, block.idx, 0);
            if (!hash_is_all_ff(block.hash) &&
                block.idx < TOTAL_NUM_METADATA_BLOCKS) {
                md_cache[block.idx] = block;
                note_md_membership_update(block.idx,
                                          0,
                                          MEMBERSHIP_REASON_SEND_HD_EVICT,
                                          "send_hd_metadata",
                                          range.pba,
                                          (unsigned int)success);
            }
        }
        free(evict_buffer);
    }

    for (uint8_t i = 0; i < sent_md_count; ++i)
    {
        uint32_t idx = sent_md_idx[i];
        if (idx < TOTAL_NUM_METADATA_BLOCKS)
        {
            note_md_membership_update(idx,
                                      1,
                                      MEMBERSHIP_REASON_SEND_HD_SENT,
                                      "send_hd_metadata",
                                      range.pba,
                                      (unsigned int)i);
        }
    }

    commit_tdmd_write(reserved_hdmd_entry, &td_md_block_local);
    tdmd_dirty = 0;

    FILE *success_fptr = fopen("/tmp/timelockdriver.log", "a");
    if (success_fptr) {
        setvbuf(success_fptr, NULL, _IONBF, 0);
        fprintf(success_fptr, "SEND_HD_METADATA_SUCCESS: sent PBA %d, now current_tdmd_block=%d tdmd_idx=%d tdmd_dirty=%d\n",
                range.pba, current_tdmd_block, tdmd_idx, tdmd_dirty);
        fclose(success_fptr);
    }
}

static uint8_t collect_tdlog_needed_md_indices(const TDMetadataLogBlock *hdlog, uint32_t out_idx[MAX_MD_BLOCKS_IN_HEADER])
{
    uint8_t count = 0;
    for (uint32_t i = 0; i < LENGTH_TD_LOG_BLOCK; ++i)
    {
        uint32_t pba = hdlog->arr[i];
        if (pba >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            continue;
        }

        uint32_t md_idx = pba / METADATA_ENTRIES_PER_BLOCK;
        int seen = 0;
        for (uint8_t j = 0; j < count; ++j)
        {
            if (out_idx[j] == md_idx)
            {
                seen = 1;
                break;
            }
        }

        if (!seen)
        {
            if (count >= MAX_MD_BLOCKS_IN_HEADER)
            {
                FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
                if (fptr)
                {
                    setvbuf(fptr, NULL, _IONBF, 0);
                    fprintf(fptr,
                            "FATAL collect_tdlog_needed_md_indices overflow: log block spans >%u distinct md blocks; "
                            "truncated at pba=%u md_idx=%u (arr[%u]). Existing: ",
                            (unsigned int)MAX_MD_BLOCKS_IN_HEADER,
                            (unsigned int)pba,
                            (unsigned int)md_idx,
                            (unsigned int)i);
                    for (uint8_t k = 0; k < count; ++k)
                    {
                        fprintf(fptr, "%u ", out_idx[k]);
                    }
                    fprintf(fptr, "\n");
                    fclose(fptr);
                }
                /* Treat truncation as a fatal protocol violation — the gatekeeper
                   will scan more md blocks than the driver is supplying, so a
                   scan_cache panic is guaranteed.  Abort here instead. */
                abort();
            }
            out_idx[count++] = md_idx;
        }
    }

    return count;
}

void send_metadata()
{
    if (!map_dirty)
    {
        return;
    }

    pthread_mutex_lock(&vmd_lock);
    tle_print("snd md\n");

    for (; map_idx < LENGTH_VERSION_LOG_BLOCK; map_idx++)
    {
        l2p_block->map[map_idx].logical_block_address = UINT32_MAX;
        l2p_block->map[map_idx].physical_block_address = UINT32_MAX;
    }

    pthread_mutex_unlock(&vmd_lock);

    uint8_t success;
    char msg_buffer[MAX_MSG_LENGTH];
    char *buffer_head;
    L2PBlock version_md_block_local;
    BlockEntry *reserved_vmd_entry;
    MessageHeader header;
    DataRange range;
    unsigned int md_idx;
    int rval;

    success = 255;
    buffer_head = msg_buffer;
    reserved_vmd_entry = NULL;
    header = (MessageHeader){.num_data_ranges = 1, .num_md_blocks = 0, .disk_cmd = WRITE};
    range = (DataRange){.pba = current_vmd_block, .num_blocks = 1};

    md_idx = (current_vmd_block / METADATA_ENTRIES_PER_BLOCK);
    if (!md_cache_membership[md_idx])
    {
        header.num_md_blocks = 1;
    }

    // write header to msg buffer
    memcpy(buffer_head, &header, sizeof(header));
    buffer_head += sizeof(header);

    memcpy(buffer_head, &range, sizeof(range));
    buffer_head += sizeof(range);

    if (header.num_md_blocks)
    {
        memcpy(buffer_head, &md_cache[md_idx], sizeof(CachedTDMetadataBlock));
        buffer_head += sizeof(CachedTDMetadataBlock);
    }

    if (prepare_vmd_write(&version_md_block_local, &reserved_vmd_entry) != 0)
    {
        return;
    }

    memcpy(buffer_head, &version_md_block_local, sizeof(L2PBlock));
    buffer_head += sizeof(L2PBlock);

    header.payload_size = (uint32_t)((size_t)(buffer_head - msg_buffer) - sizeof(header));
    memcpy(msg_buffer, &header, sizeof(header));

    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, msg_buffer, buffer_head - msg_buffer, conn_fd);
    rval = (int)gk_recv(&success, sizeof(success));

    if (rval != (int)sizeof(success))
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "write RVAL is %d, size is %zu, success is %d\n", rval, sizeof(success), success);
        fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
        fclose(fptr);
        exit(1);
    }

    if (success == CHECKER_WRITE_DENIED)
    {
        release_reserved_block(reserved_vmd_entry);
        log_metadata_reject_context("send_metadata", success, range.pba, md_idx);
        fail_metadata_reject_no_rebuild("send_metadata", success, range.pba, md_idx);
    }

    if (success == CHECKER_FRESHNESS_REJECT)
    {
        release_reserved_block(reserved_vmd_entry);
        log_metadata_reject_context("send_metadata", success, range.pba, md_idx);
        fail_metadata_reject_no_rebuild("send_metadata", success, range.pba, md_idx);
    }

    // Checker has said that we should evict n blocks from the cache.
    if (success)
    {
        if (success > MAX_MD_BLOCKS_IN_HEADER) {
            tle_print1("Too many blocks evicted: ", (unsigned int)success);
        }
        uint8_t *evict_buffer = malloc(sizeof(CachedTDMetadataBlock) * success);
        size_t evict_bytes = sizeof(CachedTDMetadataBlock) * success;
        int rval = (int)gk_recv(evict_buffer, evict_bytes);
        if (rval != (int)evict_bytes)
        {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "evict RVAL is %d, expected is %zu, success is %u\n", rval, evict_bytes, (unsigned int)success);
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
            free(evict_buffer);
            exit(1);
        }
        CachedTDMetadataBlock block;
        for (int i = 0; i < success; ++i)
        {
            block = ((CachedTDMetadataBlock *)evict_buffer)[i];
            if (!hash_is_all_ff(block.hash) &&
                block.idx < TOTAL_NUM_METADATA_BLOCKS) {
                md_cache[block.idx] = block;
                note_md_membership_update(block.idx,
                                          0,
                                          MEMBERSHIP_REASON_SEND_METADATA_EVICT,
                                          "send_metadata",
                                          range.pba,
                                          (unsigned int)success);
            }
        }
        free(evict_buffer);
    }

    if (header.num_md_blocks)
    {
        note_md_membership_update(md_idx,
                                  1,
                                  MEMBERSHIP_REASON_SEND_METADATA_SENT,
                                  "send_metadata",
                                  range.pba,
                                  header.num_md_blocks);
    }

    commit_vmd_write(reserved_vmd_entry, &version_md_block_local);
    map_dirty = 0;
}

int send_control_command(enum DiskCommand command)
{
    uint8_t num_evicted = 0;
    char msg_buffer[STD_MSG_HEADER_SIZE];
    MessageHeader header = {.payload_size = 0, .num_data_ranges = 0, .num_md_blocks = 0, .disk_cmd = command};

    // SYNC preserves driver's md_cache_membership assumptions, since recovery now
    // invalidates membership when recovery completes. Subsequent writes will
    // re-populate the cache on-demand.
    header.payload_size = 0;
    memcpy(msg_buffer, &header, sizeof(header));
    // log_header_bytes("control_send", &header, msg_buffer, sizeof(header));

    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, msg_buffer, sizeof(header), conn_fd);
    
    // For SYNC, gatekeeper sends back evicted cache blocks.
    // Some slots can be uninitialized placeholders; ignore those on hash=0xFF..FF.
    if (command == SYNC) {
        // First byte: count of evicted blocks
        int rval = (int)gk_recv(&num_evicted, sizeof(num_evicted));
        if (rval != (int)sizeof(num_evicted)) {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "SYNC count RVAL is %d, size is %zu\n", rval, sizeof(num_evicted));
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
            return -1;
        }

        if (num_evicted > MAX_MD_BLOCKS_IN_HEADER) {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(fptr, "SYNC evict count %u exceeds MAX_MD_BLOCKS_IN_HEADER=%u\n",
                    (unsigned int)num_evicted,
                (unsigned int)MAX_MD_BLOCKS_IN_HEADER);
            fclose(fptr);
            return -1;
        }
        
        // Read evicted cache blocks
        uint32_t bytes_to_recv = num_evicted * sizeof(CachedTDMetadataBlock);
        if (bytes_to_recv > 0) {
            CachedTDMetadataBlock *evict_buffer = malloc(bytes_to_recv);
            if (!evict_buffer) {
                FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
                setvbuf(fptr, NULL, _IONBF, 0);
                fprintf(fptr, "Failed to allocate evict buffer for %u bytes\n", bytes_to_recv);
                fclose(fptr);
                return -1;
            }
            
            int evict_rval = (int)gk_recv(evict_buffer, bytes_to_recv);
            if (evict_rval != (int)bytes_to_recv) {
                FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
                setvbuf(fptr, NULL, _IONBF, 0);
                fprintf(fptr, "SYNC evict RVAL is %d, expected %u\n", evict_rval, bytes_to_recv);
                fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
                fclose(fptr);
                free(evict_buffer);
                return -1;
            }

            // SYNC returns a cache snapshot for transport compatibility. We do
            // not merge it into md_cache because slots may be placeholders or
            // stale relative to the driver's authoritative host-side metadata.
            // We only consume bytes to keep the stream aligned.
            // Apply SYNC blocks only when the gatekeeper has real (non-0xFF)
            // hashes - this happens during recovery, where the gatekeeper has
            // replayed the log and holds the authoritative hash state.
            // During a fresh run the gk cache is 0xFF so we ignore those.
            for (uint32_t si = 0; si < (uint32_t)num_evicted; ++si) {
                CachedTDMetadataBlock *sb = &evict_buffer[si];
                if (!hash_is_all_ff(sb->hash) &&
                    sb->idx < TOTAL_NUM_METADATA_BLOCKS) {
                    md_cache[sb->idx] = *sb;
                }
            }

            free(evict_buffer);
        }
        return 0;
    }
    
    // For other commands, receive 1 byte response
    uint8_t success = 0;
    int rval = (int)gk_recv(&success, sizeof(success));

    if (rval != (int)sizeof(success))
    {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "control RVAL is %d, size is %zu, cmd is %d (%s)\n", rval, sizeof(success), command, enum_to_str(command));
        fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
        fclose(fptr);
        return -1;
    }

    return 0;
}

int flush_pending_metadata()
{
    FILE *flush_fptr = fopen("/tmp/timelockdriver.log", "a");
    if (flush_fptr) {
        setvbuf(flush_fptr, NULL, _IONBF, 0);
        fprintf(flush_fptr, "FLUSH_PENDING_METADATA_ENTRY: map_dirty=%d tdmd_dirty=%d current_tdmd_block=%d tdmd_idx=%d\n",
                map_dirty, tdmd_dirty, current_tdmd_block, tdmd_idx);
        fclose(flush_fptr);
    }

    pthread_mutex_lock(&write_lock);
    if (map_dirty)
    {
        if (td_metadata)
        {
            pthread_mutex_lock(&tdmd_lock);
            if (tdmd_dirty && tdmd_idx < LENGTH_TD_LOG_BLOCK)
            {
                td_md_block->arr[tdmd_idx++] = current_vmd_block;
                tdmd_dirty = 1;
            }
            pthread_mutex_unlock(&tdmd_lock);
        }
        
        if (send_control_command(SYNC) != 0) {
            pthread_mutex_unlock(&write_lock);
            return -1;
        }
        send_metadata();
    }

    if (td_metadata && tdmd_dirty)
    {
        if (send_control_command(SYNC) != 0) {
            pthread_mutex_unlock(&write_lock);
            return -1;
        }
        FILE *before_send_fptr = fopen("/tmp/timelockdriver.log", "a");
        if (before_send_fptr) {
            setvbuf(before_send_fptr, NULL, _IONBF, 0);
            fprintf(before_send_fptr, "FLUSH_CALLING_SEND_HD_METADATA: current_tdmd_block=%d tdmd_idx=%d tdmd_dirty=%d\n",
                    current_tdmd_block, tdmd_idx, tdmd_dirty);
            fclose(before_send_fptr);
        }
        send_hd_metadata();
        FILE *after_send_fptr = fopen("/tmp/timelockdriver.log", "a");
        if (after_send_fptr) {
            setvbuf(after_send_fptr, NULL, _IONBF, 0);
            fprintf(after_send_fptr, "FLUSH_AFTER_SEND_HD_METADATA: current_tdmd_block=%d tdmd_idx=%d tdmd_dirty=%d\n",
                    current_tdmd_block, tdmd_idx, tdmd_dirty);
            fclose(after_send_fptr);
        }
    }
    if (send_control_command(SYNC) != 0) {
        pthread_mutex_unlock(&write_lock);
        return -1;
    }

    pthread_mutex_unlock(&write_lock);
    return 0;
}

void scan_disk(unsigned int recovery_timestamp,
               unsigned int recovery,
               unsigned int versioning_metadata,
               unsigned int td_metadata)
{
    pthread_mutex_lock(&l2p_lock);
    
    // Ensure log pointers are initialized before scanning
    if (current_vmd_block == -1)
    {
        current_vmd_block = LENGTH_VERSION_LOG_BLOCK;
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "scan_disk: initializing current_vmd_block to default %d\n", current_vmd_block);
        fclose(fptr);
    }
    if (current_tdmd_block == -1)
    {
        current_tdmd_block = LENGTH_TD_LOG_BLOCK - 2;
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "scan_disk: initializing current_tdmd_block to default %d\n", current_tdmd_block);
        fclose(fptr);
    }
    
    if (versioning_metadata)
    {
        tle_print1("Recovery timestamp: ", recovery_timestamp);

        if (recovery_timestamp != 0)
        {
            reset_recovery_diagnostics();
        }

        char ptr_chase_msg_buffer[sizeof(unsigned int) + MAX_MAPPING_SIZE];
        char *buffer_head = ptr_chase_msg_buffer;

        MessageHeader ptr_chase_header = {
            .payload_size = 0,
            .num_data_ranges = 1,
            .num_md_blocks = 0,
            .disk_cmd = READ,
        };

        // Starting location should be the recovered/determined current_vmd_block, not hard-coded
        DataRange range = {.pba = current_vmd_block, .num_blocks = 1};
        mark_free_blocks[current_vmd_block] = 0;

        if (td_metadata)
        {
            // Replay the committed HD log chain so every historical HDMD block and
            // the current tail cursor slot stay reserved from data allocation.
            mark_hdlog_chain_reserved();
            td_md_block->arr[tdmd_idx++] = current_vmd_block;
            td_md_block->arr[tdmd_idx++] = current_tdmd_block;
        }

        // reserve space for header; overwrite with finalized payload_size before send
        buffer_head += sizeof(ptr_chase_header);
        int first = 1;
        unsigned int block_count = 0;

        TDMetadataBlock read_block;

        struct timespec start, finish, delta;
        clock_gettime(CLOCK_REALTIME, &start);
        while (true)
        {
            memcpy(buffer_head, &range, sizeof(range));
            buffer_head += sizeof(range);

            ptr_chase_header.payload_size = (uint32_t)((size_t)(buffer_head - ptr_chase_msg_buffer) - sizeof(ptr_chase_header));
            memcpy(ptr_chase_msg_buffer, &ptr_chase_header, sizeof(ptr_chase_header));

            conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, ptr_chase_msg_buffer, buffer_head - ptr_chase_msg_buffer, conn_fd);
            int rval = (int)gk_recv(l2p_block, sizeof(L2PBlock));

            if (rval != (int)sizeof(L2PBlock))
            {
                FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
                setvbuf(fptr, NULL, _IONBF, 0);
                fprintf(fptr, "scan RVAL is %d, size is %zu\n", rval, sizeof(L2PBlock));
                fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
                fclose(fptr);
                break;
            }

            if (current_seed != l2p_block->seed && !first || l2p_block->seed == 0)
            {
                break;
            }

            if (l2p_block->ptr >= TOTAL_PHYSICAL_NUM_BLOCKS)
            {
                FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
                if (fptr)
                {
                    setvbuf(fptr, NULL, _IONBF, 0);
                    fprintf(fptr, "scan pointer out of range: ptr=%u max=%u\n", l2p_block->ptr, (unsigned int)TOTAL_PHYSICAL_NUM_BLOCKS);
                    fclose(fptr);
                }
                break;
            }

            current_vmd_block = l2p_block->ptr;

            if (recovery_timestamp == 0)
            {
                memcpy(&read_block, &md_cache[range.pba / METADATA_ENTRIES_PER_BLOCK], sizeof(read_block));
                parse_metadata(read_block.arr[range.pba % (METADATA_ENTRIES_PER_BLOCK)], l2p_block);
            }
            else
            {
                memcpy(&read_block, &md_cache[range.pba / METADATA_ENTRIES_PER_BLOCK], sizeof(read_block));
                log_recovery_metadata_sample(range.pba,
                                             read_block.arr[range.pba % (METADATA_ENTRIES_PER_BLOCK)],
                                             l2p_block,
                                             recovery_timestamp);
                parse_metadata_recovery(read_block.arr[range.pba % (METADATA_ENTRIES_PER_BLOCK)], l2p_block, recovery_timestamp);
            }

            block_count++;
            first = 0;
            current_seed = l2p_block->seed;
            mark_free_blocks[l2p_block->ptr] = 0;
            range.pba = l2p_block->ptr;
            buffer_head -= sizeof(range);
        }
        if (recovery)
        {
            clock_gettime(CLOCK_REALTIME, &finish);
            delta = diff_timespec(&finish, &start);
            printf("Init time: %d.%.9ld\n", (int)delta.tv_sec, delta.tv_nsec);
            printf("Block count: %u\n", block_count);
        }

        if (recovery_timestamp != 0)
        {
            log_recovery_diagnostics(recovery_timestamp);
        }
    }

    // Never allocate bootstrap metadata slots even if current pointers moved.
    // The checker treats these bootstrap PBAs as metadata-reserved locations.
    if (LENGTH_VERSION_LOG_BLOCK < TOTAL_PHYSICAL_NUM_BLOCKS)
    {
        mark_free_blocks[LENGTH_VERSION_LOG_BLOCK] = 0;
    }
    if ((LENGTH_TD_LOG_BLOCK - 2) < TOTAL_PHYSICAL_NUM_BLOCKS)
    {
        mark_free_blocks[LENGTH_TD_LOG_BLOCK - 2] = 0;
    }

    // Initialize freelist
    for (int i = 0; i < TOTAL_PHYSICAL_NUM_BLOCKS; i++)
    {
        if (mark_free_blocks[i] == 1)
        {
            BlockEntry *versioning_entry = (struct BlockEntry *)malloc(sizeof(struct BlockEntry));
            versioning_entry->physical_block_id = i;
            versioning_entry->keep_duration = 0;
            versioning_entry->time_written = 0;
            versioning_entry->next = NULL;
            enqueue_list(versioning_entry, freelist, &freelist_lock);
            segment_list[i / BLOCKS_PER_SEGMENT]->free_blocks++;
        }
        else
        {
            // tle_print1("Not free:", i);
        }
    }
    free(mark_free_blocks);
    mark_free_blocks = NULL;

    if (current_vmd_block == LENGTH_VERSION_LOG_BLOCK)
    {
        srand(time(NULL));
        current_seed = rand();
    }
    else if (current_vmd_block < 0 || current_vmd_block >= TOTAL_PHYSICAL_NUM_BLOCKS)
    {
        current_vmd_block = LENGTH_VERSION_LOG_BLOCK;
        map_idx = 0;
    }
    // NOTE: there is intentionally no third else-if here.
    // When the loop terminates (by seed mismatch, seed==0, or out-of-bounds ptr),
    // current_vmd_block is already set to the correct next-write PBA by the last
    // accepted iteration.  Using l2p_block->ptr after a seed-mismatch break would
    // follow a stale pointer from a foreign chain block into an unallocated region.

    l2p_block->seed = current_seed;

    tle_print1("starting block: ", current_vmd_block);
    tle_print1("seed: ", l2p_block->seed);
    tle_print1("next: ", l2p_block->ptr);
    tle_print1("free physical blocks: ", freelist_size);
    tle_print1("versioning state: ", versioning_metadata);

    pthread_mutex_unlock(&l2p_lock);
}

static unsigned int mdblock_checksum(const CachedTDMetadataBlock *block)
{
    const unsigned char *bytes = (const unsigned char *)&block->mdblock;
    unsigned int checksum = 2166136261u;
    for (unsigned int i = 0; i < sizeof(block->mdblock); ++i)
    {
        checksum ^= bytes[i];
        checksum *= 16777619u;
    }
    return checksum;
}

void build_cache()
{
    enum { RECOVERY_MAX_MD_REQUEST = 4 };
    unsigned int recovery_phase2_step = 0;

    // Sanity check: ensure Constants.TOTAL_NUM_METADATA_BLOCKS matches our expectations
    // This detects discrepancies between verified checker and C driver early
    char debug_msg[256];
    snprintf(debug_msg, sizeof(debug_msg),
             "Driver build_cache: TOTAL_NUM_METADATA_BLOCKS=%lu (physical=%lu, metadata_entries_per_block=%lu)",
             (unsigned long)TOTAL_NUM_METADATA_BLOCKS,
             (unsigned long)TOTAL_PHYSICAL_NUM_BLOCKS,
             (unsigned long)METADATA_ENTRIES_PER_BLOCK);
    FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
    setvbuf(fptr, NULL, _IONBF, 0);
    fprintf(fptr, "%s\n", debug_msg);
    fclose(fptr);
    
    // The gatekeeper must send exactly TOTAL_NUM_METADATA_BLOCKS init records
    // If it sends more or fewer, we will detect it when the socket closes or times out
    
    char cache_build_msg_buffer[sizeof(unsigned int) + MAX_MAPPING_SIZE];
    char *cache_build_head = cache_build_msg_buffer;

    MessageHeader cache_header = {
        .payload_size = 0,
        .num_data_ranges = 1,
        .num_md_blocks = 0,
        .disk_cmd = INITCOUNTERS,
    };

    // reserve space for header; overwrite with finalized payload_size before send
    cache_build_head += STD_MSG_HEADER_SIZE;

    // unsigned int idx_adjusted = cache_idx * METADATA_ENTRIES_PER_BLOCK;
    DataRange dr;
    memset(&dr, 0, sizeof(dr));
    dr.pba = 0;
    dr.num_blocks = 1;
    // = {.pba = 0, .num_blocks = 1};
    memcpy(cache_build_head, &dr, DATA_RANGE_SIZE);
    cache_build_head += DATA_RANGE_SIZE;

    cache_header.payload_size = (uint32_t)((size_t)(cache_build_head - cache_build_msg_buffer) - sizeof(cache_header));
    memcpy(cache_build_msg_buffer, &cache_header, sizeof(cache_header));

    conn_fd = send_message(DESTINATION_IP, PORT_NUMBER, cache_build_msg_buffer, cache_build_head - cache_build_msg_buffer, conn_fd);
    int blocks_received = 0;
    for (int cache_idx = 0; cache_idx < TOTAL_NUM_METADATA_BLOCKS; ++cache_idx)
    {
        int rval = (int)gk_recv(&md_cache[cache_idx], sizeof(CachedTDMetadataBlock));

        if (rval != (int)sizeof(CachedTDMetadataBlock))
        {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
                fprintf(fptr, "scan RVAL is %d, size is %zu, cache_idx=%d, blocks_received=%d, expected=%lu\n",
                    rval, sizeof(CachedTDMetadataBlock), cache_idx, blocks_received, (unsigned long)TOTAL_NUM_METADATA_BLOCKS);
            fprintf(fptr, "recv: %s (%d)\n", strerror(errno), errno);
            fclose(fptr);
            break;
        }
        blocks_received++;
        if (verbose_cache_log)
        {
            unsigned int checksum = mdblock_checksum(&md_cache[cache_idx]);
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            setvbuf(fptr, NULL, _IONBF, 0);
            fprintf(
                fptr,
                "CACHE_REBUILD_ENTRY seq=%d idx=%u counter=%u checksum=%u",
                cache_idx,
                md_cache[cache_idx].idx,
                md_cache[cache_idx].counter,
                checksum);
            fprintf(fptr, "\n");
            fclose(fptr);
        }
    }
    
    if (blocks_received != TOTAL_NUM_METADATA_BLOCKS) {
        FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
        setvbuf(fptr, NULL, _IONBF, 0);
        fprintf(fptr, "WARNING: Received %d metadata blocks but expected %lu\n", blocks_received, (unsigned long)TOTAL_NUM_METADATA_BLOCKS);
        fclose(fptr);
    }

    // Phase 2: Recovery cache request protocol.
    // For each step, gatekeeper sends needed md indices, driver replies with those
    // blocks, then gatekeeper returns updated blocks for the same step.
    for (;;) {
        uint32_t n_needed = 0;
        int rv = (int)gk_recv(&n_needed, sizeof(n_needed));
        if (rv != (int)sizeof(n_needed)) {
            FILE *fptr = fopen("/tmp/timelockdriver.log", "a");
            if (fptr) {
                setvbuf(fptr, NULL, _IONBF, 0);
                fprintf(fptr, "build_cache phase2: recv count failed rv=%d errno=%d\n", rv, errno);
                fclose(fptr);
            }
            break;
        }
        if (n_needed == 0xFFFFFFFFU) {
            // After recovery completes, invalidate all cache membership assumptions.
            // The cache may contain stale or uninitialized entries from initialization.
            // Driver will re-populate cache on-demand during normal operation.
            for (unsigned int i = 0; i < TOTAL_NUM_METADATA_BLOCKS; ++i) {
                note_md_membership_update(i,
                                          0,
                                          MEMBERSHIP_REASON_RECOVERY_RESET,
                                          "build_cache_recovery_done",
                                          0,
                                          0);
            }
            break;
        }

        if (n_needed > RECOVERY_MAX_MD_REQUEST) {
            break;
        }

        uint32_t needed_idx[RECOVERY_MAX_MD_REQUEST];
        for (uint32_t k = 0; k < n_needed; ++k) {
            rv = (int)gk_recv(&needed_idx[k], sizeof(uint32_t));
            if (rv != (int)sizeof(uint32_t)) {
                break;
            }
        }

        for (uint32_t k = 0; k < n_needed; ++k) {
            uint32_t idx = needed_idx[k];
            if (idx >= TOTAL_NUM_METADATA_BLOCKS) {
                CachedTDMetadataBlock zero_block;
                memset(&zero_block, 0, sizeof(zero_block));
                gk_send(&zero_block, sizeof(zero_block));
            } else {
                gk_send(&md_cache[idx], sizeof(CachedTDMetadataBlock));
            }
        }

        uint32_t n_updated = 0;
        rv = (int)gk_recv(&n_updated, sizeof(n_updated));
        if (rv != (int)sizeof(n_updated)) {
            break;
        }

        for (uint32_t k = 0; k < n_updated; ++k) {
            CachedTDMetadataBlock updated;
            rv = (int)gk_recv(&updated, sizeof(updated));
            if (rv != (int)sizeof(updated)) {
                break;
            }
            if (updated.idx < TOTAL_NUM_METADATA_BLOCKS) {
                md_cache[updated.idx] = updated;
            }
        }

        recovery_phase2_step++;
    }

    // md_cache_membership tracks checker cache residency, not host ownership.
    // build_cache gives us host copies of metadata but does not imply checker-side cache presence.
    for (int i = 0; i < TOTAL_NUM_METADATA_BLOCKS; ++i)
    {
        note_md_membership_update((unsigned int)i,
                                  0,
                                  MEMBERSHIP_REASON_BUILD_CACHE_RESET,
                                  "build_cache",
                                  0,
                                  0);
    }
}

void parse_metadata(MetadataEntry metadata_entry, L2PBlock *l2p_block)
{
    for (int i = 0; i < LENGTH_VERSION_LOG_BLOCK; ++i)
    {
        L2PEntry l2p_entry = l2p_block->map[i];
        // Skip any entry where either sentinel field is UINT32_MAX; a half-written
        // or uninitialized entry is not valid and must not be applied.
        if (l2p_entry.logical_block_address == UINT32_MAX || l2p_entry.physical_block_address == UINT32_MAX)
        {
            continue;
        }
        // Skip entries with addresses that are outside the array bounds; applying
        // them would corrupt l2pmap, p2lmap, or mark_free_blocks.
        if (l2p_entry.physical_block_address >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            continue;
        }
        if (l2p_entry.logical_block_address >= (unsigned int)TOTAL_LOGICAL_NUM_BLOCKS)
        {
            continue;
        }
        mark_free_blocks[l2p_entry.physical_block_address] = 0;

        BlockEntry *versioning_entry = (struct BlockEntry *)malloc(sizeof(struct BlockEntry));

        versioning_entry->physical_block_id = l2p_entry.physical_block_address;
        versioning_entry->keep_duration = metadata_entry.keep_duration;
        versioning_entry->time_written = metadata_entry.time_written;
        BlockEntry *curr_mapping_entry = l2pmap[l2p_entry.logical_block_address];
        l2pmap[l2p_entry.logical_block_address] = versioning_entry;
        p2lmap[versioning_entry->physical_block_id] = l2p_entry.logical_block_address;
    }
}

void parse_metadata_recovery(MetadataEntry metadata_entry, L2PBlock *l2p_block, unsigned int recovery_timestamp)
{
    // tle_print1("timestamp read: ", metadata_entry.time_written);

    // The gatekeeper's INITCOUNTERS rebuild path seeds metadata blocks with a
    // default byte pattern {keep_duration=0, time_written=1}. Any VMD entries
    // associated with that exact timelock tuple were never reconstructed from a
    // persisted HD metadata log and must be treated as garbage during timestamp
    // recovery rather than as valid historical mappings.
    if (metadata_entry.keep_duration == 0 && metadata_entry.time_written == 1)
    {
        recovery_skipped_uninitialized_entries += LENGTH_VERSION_LOG_BLOCK;
        return;
    }

    // Diagnostic logging for metadata entry time_written values
    FILE *time_stats_fptr = fopen("/tmp/timelockdriver.log", "a");
    if (time_stats_fptr) {
        setvbuf(time_stats_fptr, NULL, _IONBF, 0);
        fprintf(time_stats_fptr, "PARSE_MD_RECOVERY md_block time_written=%u keep=%u recovery_ts=%u\n",
                metadata_entry.time_written, metadata_entry.keep_duration, recovery_timestamp);
        fclose(time_stats_fptr);
    }

    for (int i = 0; i < LENGTH_VERSION_LOG_BLOCK; ++i)
    {
        recovery_seen_entries++;

        L2PEntry l2p_entry = l2p_block->map[i];
        // Skip any entry where either sentinel field is UINT32_MAX.
        if (l2p_entry.logical_block_address == UINT32_MAX || l2p_entry.physical_block_address == UINT32_MAX)
        {
            recovery_invalid_sentinel_entries++;
            continue;
        }
        // Skip entries with addresses that are outside the array bounds.
        if (l2p_entry.physical_block_address >= TOTAL_PHYSICAL_NUM_BLOCKS)
        {
            recovery_invalid_bounds_entries++;
            continue;
        }
        if (l2p_entry.logical_block_address >= (unsigned int)TOTAL_LOGICAL_NUM_BLOCKS)
        {
            recovery_invalid_bounds_entries++;
            continue;
        }

        recovery_candidate_entries++;
        if (metadata_entry.time_written < recovery_min_time_written)
        {
            recovery_min_time_written = metadata_entry.time_written;
        }
        if (metadata_entry.time_written > recovery_max_time_written)
        {
            recovery_max_time_written = metadata_entry.time_written;
        }

        mark_free_blocks[l2p_entry.physical_block_address] = 0;

        if (metadata_entry.time_written > recovery_timestamp)
        {
            recovery_skipped_newer_entries++;
            FILE *skip_fptr = fopen("/tmp/timelockdriver.log", "a");
            if (skip_fptr) {
                setvbuf(skip_fptr, NULL, _IONBF, 0);
                fprintf(skip_fptr, "SKIPPED_NEWER lba=%u pba=%u time_written=%u > recovery_ts=%u\n",
                        l2p_entry.logical_block_address, l2p_entry.physical_block_address,
                        metadata_entry.time_written, recovery_timestamp);
                fclose(skip_fptr);
            }
            continue;
        }

        recovery_applied_entries++;
        if (metadata_entry.time_written < recovery_min_applied_time_written)
        {
            recovery_min_applied_time_written = metadata_entry.time_written;
        }
        if (metadata_entry.time_written > recovery_max_applied_time_written)
        {
            recovery_max_applied_time_written = metadata_entry.time_written;
        }

        BlockEntry *versioning_entry = (struct BlockEntry *)malloc(sizeof(struct BlockEntry));

        versioning_entry->physical_block_id = l2p_entry.physical_block_address;
        versioning_entry->keep_duration = metadata_entry.keep_duration;
        versioning_entry->time_written = metadata_entry.time_written;
        BlockEntry *curr_mapping_entry = l2pmap[l2p_entry.logical_block_address];
        l2pmap[l2p_entry.logical_block_address] = versioning_entry;
        p2lmap[versioning_entry->physical_block_id] = l2p_entry.logical_block_address;
    }
}

void *move_expired_to_free_daemon(void *arg)
{
    while (1)
    {
        sleep(60);
        move_expired_to_free();
    }
    return NULL;
}

void *gc_daemon(void *arg)
{
    while (1)
    {
        sleep(60);
        while (do_gc)
        {
            if (gc_list->head != NULL)
            {
                perform_gc();
            }
            segment_cleaner();
        }
        do_gc = 1;
    }
    return NULL;
}

void segment_cleaner()
{
    if (read_only_mode)
    {
        return;
    }

    int target_segment = -1;
    float most_clean = 0;
    unsigned int clean_segments = 0;
    pthread_mutex_lock(&segment_lock);
    for (int i = 0; i < TOTAL_NUM_SEGMENTS; ++i)
    {
        float p_clean = ((float)segment_list[i]->free_blocks) / BLOCKS_PER_SEGMENT;
        // 2% margin for clean-ness
        if (p_clean >= .98)
        {
            clean_segments++;
        }
        // if below 2% the segment is so "in use" that it's not worth reclaiming
        else if (p_clean > .02)
        {
            if (!segment_list[i]->hot_bit && p_clean > most_clean)
            {
                most_clean = p_clean;
                target_segment = i;
            }
        }
        segment_list[i]->hot_bit = 0;
    }

    float p_clean_segments = ((float)clean_segments) / TOTAL_NUM_SEGMENTS;

    if (target_segment != -1 && p_clean_segments < .1)
    {
        segment_list[target_segment]->free_blocks = BLOCKS_PER_SEGMENT;
        pthread_mutex_unlock(&segment_lock);

        unsigned int target_offset = target_segment * BLOCKS_PER_SEGMENT;
        char buf[BLOCK_SIZE];
        for (int i = 0; i < BLOCKS_PER_SEGMENT; ++i)
        {
            unsigned int logical_address = p2lmap[target_offset + i];
            if (logical_address != UINT32_MAX)
            {
                tle_print1("LA, ", logical_address);
                device_read(buf, logical_address * BLOCK_SIZE, BLOCK_SIZE, NULL);
                device_write(buf, logical_address * BLOCK_SIZE, BLOCK_SIZE, NULL, false);
            }
        }
    }
    else
    {
        pthread_mutex_unlock(&segment_lock);
    }
}

void *metadata_daemon(void *arg)
{
    (void)arg;
    while (1)
    {
        sleep(1);
        pthread_mutex_lock(&write_lock);
        if (!read_only_mode && do_sync && map_idx > 0)
        {
            tle_print("ran sync daemon");
            send_metadata();
        }
        do_sync = 1;
        pthread_mutex_unlock(&write_lock);
    }
    return NULL;
}

void *epoch_flush_daemon(void *arg)
{
    (void)arg;
    while (1)
    {
        sleep(60);
        if (epoch_mode && kh_size(hi))
        {
            flush_epoch_timelock_set();
        }
    }
    return NULL;
}