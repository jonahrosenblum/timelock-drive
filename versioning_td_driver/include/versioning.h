#ifdef _MSC_VER
#include <intrin.h>
#else
#include <x86intrin.h>
#endif

#include <bdus.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <search.h>
#include <assert.h>

#include "socket_send.h"
#include "constants.h"

#ifndef VERSIONING_H_
#define VERSIONING_H_

extern int conn_fd;
extern int do_gc;
extern int do_sync;
extern int driver_mode;
extern int versioning_metadata;
extern int td_metadata;
extern int current_vmd_block;
extern int current_tdmd_block;
extern int tdmd_idx;
extern int persisted_tdmd_log_head;
extern int persisted_tdmd_log_tail;

typedef enum DriverMode DriverMode;
enum DriverMode
{
    MODE_NORMAL = 0,
    MODE_VERSIONING = 1,
    MODE_BAREBONES = 2,
};

struct timespec diff_timespec(const struct timespec *time1, const struct timespec *time0);

// used to track which physical block metadata
typedef struct BlockEntry BlockEntry;
struct BlockEntry
{
    BlockEntry *next;
    unsigned int physical_block_id;
    unsigned int keep_duration; // how long to keep this block
    unsigned int time_written;  // important for tie breaking when we scan the disk
};

extern CachedTDMetadataBlock md_cache[TOTAL_NUM_METADATA_BLOCKS];
extern uint8_t md_cache_membership[TOTAL_NUM_METADATA_BLOCKS];

typedef enum MembershipReason MembershipReason;
enum MembershipReason
{
    MEMBERSHIP_REASON_INIT_RESET = 0,
    MEMBERSHIP_REASON_BUILD_CACHE_RESET = 1,
    MEMBERSHIP_REASON_RECOVERY_RESET = 2,
    MEMBERSHIP_REASON_SEND_METADATA_SENT = 3,
    MEMBERSHIP_REASON_SEND_METADATA_EVICT = 4,
    MEMBERSHIP_REASON_SEND_HD_SENT = 5,
    MEMBERSHIP_REASON_SEND_HD_EVICT = 6,
    MEMBERSHIP_REASON_DEVICE_WRITE_SENT = 7,
    MEMBERSHIP_REASON_DEVICE_WRITE_EVICT = 8,
};

void note_md_membership_update(unsigned int idx,
                               uint8_t new_value,
                               MembershipReason reason,
                               const char *op,
                               unsigned int range_pba,
                               unsigned int aux);

typedef struct BlockEntryList BlockEntryList;
struct BlockEntryList
{
    BlockEntry *head;
    BlockEntry *tail;
};

typedef struct L2PEntry L2PEntry;
struct L2PEntry
{
    unsigned int logical_block_address;
    unsigned int physical_block_address;
};

typedef struct L2PBlock L2PBlock;
struct L2PBlock
{
    unsigned int ptr;
    unsigned int seed;
    L2PEntry map[511];
};

typedef struct L2PNode L2PNode;
struct L2PNode
{
    L2PBlock *block;
    L2PNode *next;
    unsigned int block_address;
};

typedef struct Segment Segment;
struct Segment
{
    unsigned int free_blocks;
    unsigned int hot_bit;
};

int device_read(char *read_buffer, uint64_t read_buffer_offset, uint32_t read_buffer_size, struct bdus_ctx *ctx);

int device_write(const char *write_buffer, uint64_t write_buffer_offset, uint32_t write_buffer_size, struct bdus_ctx *ctx, bool raw);

void versioning_init();

void block_and_node_init();

void enqueue_list(BlockEntry *entry, BlockEntryList *list, pthread_mutex_t *lock);

int fetch_gatekeeper_log_state(unsigned int *log_head, unsigned int *log_tail);

int prepare_tdmd_write(int init, TDMetadataLogBlock *prepared_block, BlockEntry **reserved_entry);

int prepare_vmd_write(L2PBlock *prepared_block, BlockEntry **reserved_entry);

void commit_tdmd_write(BlockEntry *reserved_entry, const TDMetadataLogBlock *prepared_block);

void commit_vmd_write(BlockEntry *reserved_entry, const L2PBlock *prepared_block);

void release_reserved_block(BlockEntry *reserved_entry);

void perform_gc();

void enqueue_free_id_queue(unsigned int physical_block_id, unsigned int daemon_invoke);

// if we pop an entry it is now in the l2pmap
// BlockEntry *find_free_entry_for_map(unsigned int logical_block_address, int versioning);

int set_pointer_and_reset_tdmd(int init);

int set_pointer_and_reset_vmd();

typedef struct RangeRet RangeRet;
struct RangeRet
{
    bool versioning_found;
    bool tdmd_found;
    bool epoch_reuse;
};

RangeRet *find_free_range(unsigned int logical_block_address,
                          unsigned int versioning_metadata,
                          unsigned int td_metadata,
                          DataRange *range,
                          unsigned int num_blocks);

BlockEntry *pop_nth_in_freelist(unsigned int n);

BlockEntry *pop_top_of_freelist();

int scan_metadata(TDMetadataBlock *block_of_blocks, unsigned int physical_block_id);

// void scan_metadata(TDMetadataBlock *block_of_blocks, unsigned int start, unsigned int num_entries);

int scan_metadata_recovery(TDMetadataBlock *block_of_blocks, unsigned int physical_block_id, unsigned int recovery_timestamp);

void scan_disk(unsigned int recovery_timestamp,
               unsigned int recovery,
               unsigned int versioning_metadata,
               unsigned int td_metadata);

void build_cache();

int flush_pending_metadata();

int send_control_command(enum DiskCommand command);

void parse_metadata(MetadataEntry metadata_entry, L2PBlock *l2p_block);

void parse_metadata_recovery(MetadataEntry metadata_entry, L2PBlock *l2p_block, unsigned int recovery_timestamp);

void send_metadata();

void send_hd_metadata();

void move_expired_to_free();

void flush_epoch_timelock_set();

void *move_expired_to_free_daemon(void *arg);

void *gc_daemon(void *arg);

void segment_cleaner();

void *metadata_daemon(void *arg);

void *epoch_flush_daemon(void *arg);

bool hash_is_all_ff(const char hash[32]);

#endif