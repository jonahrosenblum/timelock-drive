#ifndef CONSTANTS_H_
#define CONSTANTS_H_

#include <stdint.h>
#include <stddef.h>

/*
Important: I have only tested this for sizes that are powers of 2.
*multiples* of powers of two also work e.g. 5 GiB works but (5 GiB - 1 byte) may not work.

The block size can be increased but it needs to be a power of two - read the bdus spec before doing this.
*/

enum __attribute__((__packed__)) DiskCommand
{
    READ = 0b00000000,
    // READ_MD = 0b00000001,
    WRITE = 0b00000001,
    SYNC = 0b00000010,
    INITCOUNTERS = 0b00000011,
    FINISH = 0b00000100,
    TIMELOCK = 0b00000101,
    UNFREEZE = 0b00000110,
    GET_MD_TAG = 0b00000111,
    IDENTIFY = 0b00001000,
};

inline const char *enum_to_str(enum DiskCommand cmd)
{
    switch (cmd)
    {
    case READ:
        return "READ";
    // case READ_MD:
    //     return "READ_MD";
    case WRITE:
        return "WRITE";
    case SYNC:
        return "SYNC";
    case INITCOUNTERS:
        return "INITCOUNTERS";
    case FINISH:
        return "FINISH";
    case TIMELOCK:
        return "TIMELOCK";
    case UNFREEZE:
        return "UNFREEZE";
    case GET_MD_TAG:
        return "GET_MD_TAG";
    case IDENTIFY:
        return "IDENTIFY";
    }
    return "INVALID";
}

typedef struct MessageHeader MessageHeader;
struct MessageHeader
{
    uint32_t payload_size;
    unsigned int num_data_ranges;
    uint8_t num_md_blocks;
    enum DiskCommand disk_cmd;
};

typedef struct DataRange DataRange;
struct DataRange
{
    unsigned int pba;
    uint8_t num_blocks;
};

_Static_assert(sizeof(enum DiskCommand) == 1, "DiskCommand must be 1 byte on the wire");
_Static_assert(sizeof(MessageHeader) == 12, "MessageHeader wire layout must be 12 bytes");
_Static_assert(offsetof(MessageHeader, payload_size) == 0, "MessageHeader.payload_size offset mismatch");
_Static_assert(offsetof(MessageHeader, num_data_ranges) == 4, "MessageHeader.num_data_ranges offset mismatch");
_Static_assert(offsetof(MessageHeader, num_md_blocks) == 8, "MessageHeader.num_md_blocks offset mismatch");
_Static_assert(offsetof(MessageHeader, disk_cmd) == 9, "MessageHeader.disk_cmd offset mismatch");
_Static_assert(sizeof(DataRange) == 8, "DataRange wire layout must be 8 bytes");
_Static_assert(offsetof(DataRange, pba) == 0, "DataRange.pba offset mismatch");
_Static_assert(offsetof(DataRange, num_blocks) == 4, "DataRange.num_blocks offset mismatch");

// const EVICT_OBJ_SIZE: BoundedInts.uint32 := 1 + (MAX_MD_BLOCKS_IN_HEADER * sizeof_hash_block_obj)

#define BLOCK_SIZE 4096
#define BLOCKS_PER_SEGMENT 1024
#define MAX_STD_MSG_BUFFER_SIZE (BLOCK_SIZE * (MAX_MAPPING_COUNT + 2)) // 256 KiB + 4k for version metadata + 4k for timelock metadata
#define STD_MSG_HEADER_SIZE (sizeof(MessageHeader))                    // payload size (4) + num blocks (4) + num md blocks (1) + disk command (1) + padding (2)
#define DATA_RANGE_SIZE (sizeof(DataRange))
#define MAX_MD_BLOCKS_IN_HEADER 5
#define MAX_MAPPING_COUNT (262144 / BLOCK_SIZE) // Magic number based on observations, add one to account for occasional version metadata.
#define MAX_MAPPING_SIZE (MAX_MAPPING_COUNT * sizeof(DataRange))
#define one_GB (1073741824UL)
#ifndef LOGICAL_DISK_SIZE
#define LOGICAL_DISK_SIZE (10 * one_GB)
#endif
// #define LOGICAL_DISK_SIZE (10 * one_GB)
#ifndef PHYSICAL_DISK_SIZE
#define PHYSICAL_DISK_SIZE (10 * one_GB)
#endif
#define MAX_MSG_LENGTH (STD_MSG_HEADER_SIZE + MAX_MAPPING_SIZE + MAX_STD_MSG_BUFFER_SIZE + (BLOCK_SIZE * MAX_MD_BLOCKS_IN_HEADER))
#define TOTAL_PHYSICAL_NUM_BLOCKS (PHYSICAL_DISK_SIZE / BLOCK_SIZE)
#define TOTAL_LOGICAL_NUM_BLOCKS (LOGICAL_DISK_SIZE / BLOCK_SIZE)
#define METADATA_ENTRIES_PER_BLOCK (BLOCK_SIZE / sizeof(MetadataEntry))
#define TOTAL_NUM_METADATA_BLOCKS (TOTAL_PHYSICAL_NUM_BLOCKS / METADATA_ENTRIES_PER_BLOCK) // elite naming schemes
// #define TOTAL_PHYSICAL_DISK_BLOCKS (TOTAL_NUM_BLOCKS + TOTAL_NUM_METADATA_BLOCKS)
#define LENGTH_VERSION_LOG_BLOCK ((BLOCK_SIZE - (2 * sizeof(unsigned int))) / (sizeof(unsigned int) + sizeof(unsigned int)))
#define LENGTH_TD_LOG_BLOCK ((BLOCK_SIZE - (3 * sizeof(unsigned int))) / sizeof(unsigned int))
#define TOTAL_NUM_SEGMENTS (TOTAL_PHYSICAL_NUM_BLOCKS / BLOCKS_PER_SEGMENT)
#define DEFAULT_KEEP_DURATION 60
#define DESTINATION_IP "localhost" //"141.212.111.149"
#define PORT_NUMBER 10107
#define EVICT_OBJ_SIZE 1 + (MAX_MD_BLOCKS_IN_HEADER * sizeof(CachedTDMetadataBlock))

// used to track which physical block metadata
typedef struct MetadataEntry MetadataEntry;
struct MetadataEntry
{
    unsigned int keep_duration; // how long to keep this block?
    unsigned int time_written;  // when was this block written? (used for enforcing ordering for physical blocks that point to the same logical block)
};

typedef struct TDMetadataBlock TDMetadataBlock;
struct TDMetadataBlock
{
    MetadataEntry arr[METADATA_ENTRIES_PER_BLOCK];
};

typedef struct TDMetadataLogBlock TDMetadataLogBlock;
struct TDMetadataLogBlock
{
    unsigned int arr[LENGTH_TD_LOG_BLOCK];
    unsigned int keep_duration;
    unsigned int current_time;
    unsigned int pointer_next;
};

typedef struct CachedTDMetadataBlock CachedTDMetadataBlock;
struct CachedTDMetadataBlock
{
    TDMetadataBlock mdblock;
    unsigned int idx;
    unsigned int counter;
    char hash[32];
};

#endif