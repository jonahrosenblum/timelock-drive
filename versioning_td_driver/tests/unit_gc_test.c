#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <assert.h>

#include "versioning.h"

struct bdus_ctx;
int device_read(char *read_buffer, uint64_t read_buffer_offset, uint32_t read_buffer_size, struct bdus_ctx *ctx) { return 0; }
int device_write(const char *write_buffer, uint64_t write_buffer_offset, uint32_t write_buffer_size, struct bdus_ctx *ctx, bool raw) { return 0; }

extern BlockEntryList *freelist;
extern BlockEntryList *gc_list;
extern BlockEntryList *tobe_freelist;
extern BlockEntry **l2pmap;
extern Segment **segment_list;
extern unsigned int *p2lmap;
extern int epoch_mode;
extern int tdmd_dirty;
extern pthread_mutex_t freelist_lock;

static bool list_contains(BlockEntryList *list, unsigned int physical_block_id)
{
    BlockEntry *entry = list->head;
    while (entry)
    {
        if (entry->physical_block_id == physical_block_id)
        {
            return true;
        }
        entry = entry->next;
    }
    return false;
}

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

static unsigned int allocate_logical_block(unsigned int logical_block_address)
{
    DataRange range = {0};
    RangeRet *ret = find_free_range(logical_block_address, 0, &range, 1);
    assert(ret != NULL);
    assert(range.num_blocks == 1);
    unsigned int pba = range.pba;
    free(ret);
    assert(l2pmap[logical_block_address] != NULL);
    assert(l2pmap[logical_block_address]->physical_block_id == pba);
    return pba;
}

static unsigned int allocate_logical_block_with_versioning(unsigned int logical_block_address, unsigned int versioning)
{
    DataRange range = {0};
    RangeRet *ret = find_free_range(logical_block_address, versioning, &range, 1);
    assert(ret != NULL);
    assert(range.num_blocks == 1);
    unsigned int pba = range.pba;
    free(ret);
    assert(l2pmap[logical_block_address] != NULL);
    assert(l2pmap[logical_block_address]->physical_block_id == pba);
    return pba;
}

static void expire_all_tobe_free_entries(void)
{
    BlockEntry *entry = tobe_freelist->head;
    while (entry)
    {
        entry->keep_duration = 0;
        entry = entry->next;
    }
    move_expired_to_free();
}

static void drain_gc_to_tobe_freelist(void)
{
    while (gc_list->head != NULL)
    {
        perform_gc();
    }
}

static void test_segment_cleaner_reclaims_cold_best_segment(void)
{
    versioning_init();

    for (unsigned int i = 0; i < TOTAL_PHYSICAL_NUM_BLOCKS; ++i)
    {
        p2lmap[i] = UINT32_MAX;
    }

    segment_list[0]->free_blocks = BLOCKS_PER_SEGMENT / 2;
    segment_list[0]->hot_bit = 0;
    segment_list[1]->free_blocks = BLOCKS_PER_SEGMENT / 4;
    segment_list[1]->hot_bit = 0;
    segment_list[2]->free_blocks = BLOCKS_PER_SEGMENT / 2;
    segment_list[2]->hot_bit = 1;
    segment_list[3]->free_blocks = 0;

    segment_cleaner();

    assert(segment_list[0]->free_blocks == BLOCKS_PER_SEGMENT);
    assert(segment_list[1]->free_blocks == BLOCKS_PER_SEGMENT / 4);
    assert(segment_list[2]->free_blocks == BLOCKS_PER_SEGMENT / 2);
    assert(segment_list[3]->free_blocks == 0);

    for (int i = 0; i < TOTAL_NUM_SEGMENTS; ++i)
    {
        assert(segment_list[i]->hot_bit == 0);
    }
}

static void test_segment_cleaner_skips_when_many_clean_segments_exist(void)
{
    versioning_init();

    for (unsigned int i = 0; i < TOTAL_PHYSICAL_NUM_BLOCKS; ++i)
    {
        p2lmap[i] = UINT32_MAX;
    }

    segment_list[0]->free_blocks = BLOCKS_PER_SEGMENT / 2;
    segment_list[0]->hot_bit = 0;
    segment_list[1]->free_blocks = BLOCKS_PER_SEGMENT;
    segment_list[1]->hot_bit = 0;
    segment_list[2]->free_blocks = 0;
    segment_list[2]->hot_bit = 0;
    segment_list[3]->free_blocks = 0;

    segment_cleaner();

    assert(segment_list[0]->free_blocks == BLOCKS_PER_SEGMENT / 2);
    assert(segment_list[1]->free_blocks == BLOCKS_PER_SEGMENT);
    assert(segment_list[2]->free_blocks == 0);
    assert(segment_list[3]->free_blocks == 0);

    for (int i = 0; i < TOTAL_NUM_SEGMENTS; ++i)
    {
        assert(segment_list[i]->hot_bit == 0);
    }
}

static void test_epoch_mode_squashes_repeated_writes_to_same_block(void)
{
    versioning_init();
    epoch_mode = 1;

    populate_freelist(3);
    unsigned int first_pba = allocate_logical_block_with_versioning(0, 1);
    unsigned int second_pba = allocate_logical_block_with_versioning(0, 1);

    assert(first_pba == second_pba);
    assert(gc_list->head == NULL);
    assert(tobe_freelist->head == NULL);
}

static void test_epoch_mode_issues_timelock_at_epoch_boundary(void)
{
    versioning_init();
    epoch_mode = 1;

    populate_freelist(3);
    unsigned int first_pba = allocate_logical_block_with_versioning(0, 1);
    unsigned int second_pba = allocate_logical_block_with_versioning(0, 1);

    assert(first_pba == second_pba);
    assert(gc_list->head == NULL);
    assert(tobe_freelist->head == NULL);

    flush_epoch_timelock_set();

    assert(tdmd_dirty == 0);
    assert(l2pmap[0] != NULL);
    assert(l2pmap[0]->time_written > 0);
    assert(l2pmap[0]->keep_duration > l2pmap[0]->time_written);
}

static void test_epoch_mode_allocates_new_block_after_epoch_boundary(void)
{
    versioning_init();
    epoch_mode = 1;

    populate_freelist(4);
    unsigned int first_pba = allocate_logical_block_with_versioning(0, 1);
    unsigned int second_pba = allocate_logical_block_with_versioning(0, 1);
    assert(first_pba == second_pba);

    flush_epoch_timelock_set();
    unsigned int third_pba = allocate_logical_block_with_versioning(0, 1);

    assert(third_pba != first_pba);
    assert(l2pmap[0] != NULL);
    assert(l2pmap[0]->physical_block_id == third_pba);
}

static void test_conservative_mode_allocates_new_block_for_repeated_writes(void)
{
    versioning_init();
    epoch_mode = 0;

    populate_freelist(4);
    unsigned int first_pba = allocate_logical_block_with_versioning(0, 1);
    unsigned int second_pba = allocate_logical_block_with_versioning(0, 1);

    assert(first_pba != second_pba);
    assert(gc_list->head != NULL);
    assert(gc_list->head->physical_block_id == first_pba);
    assert(tobe_freelist->head == NULL);
}

static void test_segment_metadata_updates_on_allocate_and_expiry(void)
{
    versioning_init();
    populate_freelist(2);

    segment_list[0]->free_blocks = 2;
    segment_list[0]->hot_bit = 0;

    unsigned int first_pba = allocate_logical_block(0);
    assert(segment_list[0]->free_blocks == 1);
    assert(segment_list[0]->hot_bit == 1);

    unsigned int second_pba = allocate_logical_block(0);
    (void)second_pba;
    assert(segment_list[0]->free_blocks == 0);
    assert(list_contains(gc_list, first_pba));

    drain_gc_to_tobe_freelist();
    assert(list_contains(tobe_freelist, first_pba));

    expire_all_tobe_free_entries();
    assert(segment_list[0]->free_blocks == 1);
}

static void test_gc_reclaims_overwritten_physical_blocks_after_expiry(void)
{
    versioning_init();
    populate_freelist(3);

    unsigned int first_pba = allocate_logical_block(0);
    unsigned int second_pba = allocate_logical_block(1);
    assert(first_pba != second_pba);

    unsigned int replacement_pba = allocate_logical_block(0);
    assert(replacement_pba != first_pba);
    assert(gc_list->head != NULL);
    assert(list_contains(gc_list, first_pba));
    assert(!list_contains(freelist, first_pba));

    drain_gc_to_tobe_freelist();
    assert(list_contains(tobe_freelist, first_pba));

    expire_all_tobe_free_entries();
    assert(list_contains(freelist, first_pba));

    unsigned int reused_pba = allocate_logical_block(2);
    assert(reused_pba == first_pba);
    assert(l2pmap[2] != NULL);
    assert(l2pmap[2]->physical_block_id == first_pba);
}

static void test_gc_returns_multiple_expired_entries_to_freelist(void)
{
    versioning_init();
    populate_freelist(6);

    unsigned int pba0 = allocate_logical_block(0);
    unsigned int pba1 = allocate_logical_block(1);
    unsigned int pba2 = allocate_logical_block(2);

    allocate_logical_block(0);
    allocate_logical_block(1);
    allocate_logical_block(2);

    assert(gc_list->head != NULL);
    assert(list_contains(gc_list, pba0));
    assert(list_contains(gc_list, pba1));
    assert(list_contains(gc_list, pba2));

    drain_gc_to_tobe_freelist();
    assert(list_contains(tobe_freelist, pba0));
    assert(list_contains(tobe_freelist, pba1));
    assert(list_contains(tobe_freelist, pba2));

    expire_all_tobe_free_entries();
    assert(list_contains(freelist, pba0));
    assert(list_contains(freelist, pba1));
    assert(list_contains(freelist, pba2));
}

int main(void)
{
    test_segment_cleaner_reclaims_cold_best_segment();
    test_segment_cleaner_skips_when_many_clean_segments_exist();
    test_epoch_mode_squashes_repeated_writes_to_same_block();
    test_epoch_mode_issues_timelock_at_epoch_boundary();
    test_epoch_mode_allocates_new_block_after_epoch_boundary();
    test_conservative_mode_allocates_new_block_for_repeated_writes();
    test_segment_metadata_updates_on_allocate_and_expiry();
    test_gc_reclaims_overwritten_physical_blocks_after_expiry();
    test_gc_returns_multiple_expired_entries_to_freelist();

    printf("PASS\n");
    return 0;
}
