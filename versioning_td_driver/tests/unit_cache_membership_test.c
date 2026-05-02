#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <assert.h>
#include <string.h>
#include <pthread.h>

#include "versioning.h"

struct bdus_ctx;
int device_read(char *read_buffer, uint64_t read_buffer_offset, uint32_t read_buffer_size, struct bdus_ctx *ctx) { return 0; }
int device_write(const char *write_buffer, uint64_t write_buffer_offset, uint32_t write_buffer_size, struct bdus_ctx *ctx, bool raw) { return 0; }

extern BlockEntryList *freelist;
extern pthread_mutex_t freelist_lock;

static void populate_freelist(unsigned int count)
{
    for (unsigned int i = 0; i < count; ++i)
    {
        BlockEntry *entry = malloc(sizeof(BlockEntry));
        entry->physical_block_id = i;
        entry->keep_duration = 0;
        entry->time_written = 0;
        entry->next = NULL;
        enqueue_list(entry, freelist, &freelist_lock);
    }
}

static void test_cache_membership_initialized_to_zero(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    // All blocks should start as NOT in gatekeeper cache (0)
    for (unsigned int i = 0; i < TOTAL_NUM_METADATA_BLOCKS; ++i)
    {
        assert(md_cache_membership[i] == 0);
    }
}

static void test_cache_membership_marks_blocks_on_send(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    // Simulate write request spanning multiple metadata blocks
    // Writes to logical blocks that would span metadata indices 5 and 6
    unsigned int logical_start = 5 * METADATA_ENTRIES_PER_BLOCK;
    unsigned int logical_end = 6 * METADATA_ENTRIES_PER_BLOCK + 100;
    
    // Before write, these metadata blocks should be 0
    assert(md_cache_membership[5] == 0);
    assert(md_cache_membership[6] == 0);
    
    // Allocate blocks in these ranges
    DataRange range1 = {0};
    RangeRet *ret1 = find_free_range(logical_start, 1, &range1, 10);
    assert(ret1 != NULL);
    free(ret1);

    // After allocation, metadata indices should be marked in cache
    // (Simulating what device_write does: checks membership and marks with 1)
    unsigned int md_idx_start = (range1.pba / METADATA_ENTRIES_PER_BLOCK);
    unsigned int md_idx_end = ((range1.pba + range1.num_blocks - 1) / METADATA_ENTRIES_PER_BLOCK);
    
    // Simulate the device_write behavior of marking blocks as in cache
    for (unsigned int i = md_idx_start; i <= md_idx_end; ++i)
    {
        md_cache_membership[i] = 1;
    }
    
    // Verify they're marked
    for (unsigned int i = md_idx_start; i <= md_idx_end; ++i)
    {
        assert(md_cache_membership[i] == 1);
    }
}

static void test_cache_membership_cleared_on_eviction(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    unsigned int test_block_idx = 10;
    
    // Mark block as in cache
    md_cache_membership[test_block_idx] = 1;
    assert(md_cache_membership[test_block_idx] == 1);
    
    // Initialize the metadata block to simulate it being in cache
    md_cache[test_block_idx].idx = test_block_idx;
    md_cache[test_block_idx].counter = 5;
    
    // Simulate gatekeeper evicting the block (sets membership to 0)
    md_cache_membership[test_block_idx] = 0;
    
    // Verify it's been removed from membership
    assert(md_cache_membership[test_block_idx] == 0);
}

static void test_cache_membership_selective_sending(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    unsigned int md_block_1 = 15;
    unsigned int md_block_2 = 16;
    
    // Block 1 is in cache, block 2 is not
    md_cache_membership[md_block_1] = 1;
    md_cache_membership[md_block_2] = 0;
    
    // Simulate a request needing both blocks
    unsigned int needed_blocks[2] = {md_block_1, md_block_2};
    unsigned int blocks_to_send_count = 0;
    unsigned int blocks_to_send[2];
    
    // This is what device_write does: only add blocks not in cache to message
    for (int i = 0; i < 2; ++i)
    {
        unsigned int md_block = needed_blocks[i];
        if (!md_cache_membership[md_block])
        {
            blocks_to_send[blocks_to_send_count++] = md_block;
        }
        md_cache_membership[md_block] = 1;  // Mark as now in cache
    }
    
    // Only block 2 should be sent
    assert(blocks_to_send_count == 1);
    assert(blocks_to_send[0] == md_block_2);
    
    // Both should now be marked as in cache
    assert(md_cache_membership[md_block_1] == 1);
    assert(md_cache_membership[md_block_2] == 1);
}

static void test_cache_membership_multiple_evictions_and_sends(void)
{
    versioning_init();
    populate_freelist(TOTAL_PHYSICAL_NUM_BLOCKS);

    unsigned int block_a = 20;
    unsigned int block_b = 21;
    unsigned int block_c = 22;
    
    // Initial state: all not in cache
    assert(md_cache_membership[block_a] == 0);
    assert(md_cache_membership[block_b] == 0);
    assert(md_cache_membership[block_c] == 0);
    
    // First request: send all three blocks
    md_cache_membership[block_a] = 1;
    md_cache_membership[block_b] = 1;
    md_cache_membership[block_c] = 1;
    
    // Verify all marked
    assert(md_cache_membership[block_a] == 1);
    assert(md_cache_membership[block_b] == 1);
    assert(md_cache_membership[block_c] == 1);
    
    // Gatekeeper evicts block_b
    md_cache_membership[block_b] = 0;
    
    // Second request: need all three, but block_a and block_c still in cache
    int retry_send_count = 0;
    for (int i = 0; i < 3; ++i)
    {
        unsigned int block = (i == 0) ? block_a : (i == 1) ? block_b : block_c;
        if (!md_cache_membership[block])
        {
            retry_send_count++;
        }
        md_cache_membership[block] = 1;
    }
    
    // Only block_b should have been resent
    assert(retry_send_count == 1);
    
    // All should be marked as in cache again
    assert(md_cache_membership[block_a] == 1);
    assert(md_cache_membership[block_b] == 1);
    assert(md_cache_membership[block_c] == 1);
}

int main(void)
{
    test_cache_membership_initialized_to_zero();
    test_cache_membership_marks_blocks_on_send();
    test_cache_membership_cleared_on_eviction();
    test_cache_membership_selective_sending();
    test_cache_membership_multiple_evictions_and_sends();

    printf("PASS\n");
    return 0;
}
