include "std-library.dfy"

module {:options "-functionSyntax:4"} Constants {
  import opened BoundedInts

  const sizeof_MetadataEntry: BoundedInts.uint32 := 8 // keep_duration/time till free/freebit (4) + time_written (4)
  const sizeof_unsigned_int: BoundedInts.uint32 := 4
  const sizeof_byte: BoundedInts.uint32 := 1
  const sizeof_hash: BoundedInts.uint32 := 32
  const sizeof_hash_block_obj: BoundedInts.uint32 := BLOCK_SIZE + sizeof_unsigned_int + sizeof_unsigned_int + sizeof_hash
  const sizeof_DiskCmdHeader: BoundedInts.uint32 := 12 // payload_size (4) + num_data_ranges (4) + num_md_blocks (1) + disk_cmd (1)
  const sizeof_DataRange: BoundedInts.uint32 := 8 // hd block address (4) + size of range (1) + padding (3)
  const MAX_MD_BLOCKS_IN_HEADER: BoundedInts.uint32 := 5
  const MAX_TD_CACHE_SIZE: BoundedInts.uint32 := 5
  const BLOCK_SIZE: BoundedInts.uint32 := 4096
  const MAX_MAPPING_COUNT: BoundedInts.uint32 := (262144 / BLOCK_SIZE) + 2 // Magic number for largest write, plus 2 for metadata.
  const MAX_STD_MSG_BUFFER_SIZE: BoundedInts.uint32 := BLOCK_SIZE * MAX_MAPPING_COUNT // 256 KiB + 4KiB for version metadata
  // const MAX_MAPPING_SIZE: BoundedInts.uint32 := MAX_MAPPING_COUNT * sizeof_unsigned_int // 4 is size of unsigned int
  const one_GB: BoundedInts.uint41 := 1073741824
  const LOGICAL_DISK_SIZE: BoundedInts.uint41 := (10 as BoundedInts.uint41) * one_GB // Match PHYSICAL_DISK_SIZE
  const PHYSICAL_DISK_SIZE: BoundedInts.uint41 := (10 as BoundedInts.uint41) * one_GB
  // const MAX_MSG_LENGTH: BoundedInts.uint32 := sizeof_DiskCmdHeader + MAX_MAPPING_SIZE + MAX_STD_MSG_BUFFER_SIZE
  const TOTAL_DISK_BLOCKS: BoundedInts.uint32 := ( PHYSICAL_DISK_SIZE / BLOCK_SIZE as BoundedInts.uint41 ) as BoundedInts.uint32
  const METADATA_ENTRIES_PER_BLOCK: BoundedInts.uint32 := BLOCK_SIZE / sizeof_MetadataEntry
  const METADATA_ENTRIES_PER_BLOCK_PLUS_ONE: BoundedInts.uint32 := METADATA_ENTRIES_PER_BLOCK + 1
  const TOTAL_NUM_METADATA_BLOCKS: BoundedInts.uint32 := (TOTAL_DISK_BLOCKS / METADATA_ENTRIES_PER_BLOCK )
  const TOTAL_NUM_MD_PER_LOG: BoundedInts.uint32 := (BLOCK_SIZE - (3 * sizeof_unsigned_int)) / sizeof_unsigned_int
  // Reserved last valid physical block for persisting gatekeeper replay pointers.
  const LOG_STATE_BLOCK: BoundedInts.uint32 := TOTAL_DISK_BLOCKS - 1
  const EVICT_OBJ_SIZE: BoundedInts.uint32 := 1 + (MAX_MD_BLOCKS_IN_HEADER * sizeof_hash_block_obj)
  const PORT_NUMBER: BoundedInts.uint32 := 10107
  const BUFFER_SIZE: BoundedInts.uint32 :=
    (MAX_MAPPING_COUNT * sizeof_DataRange) +
    (BLOCK_SIZE * MAX_MAPPING_COUNT) +
    (MAX_MD_BLOCKS_IN_HEADER * sizeof_hash_block_obj)
  // const MD_INIT_STATE: seq<BoundedInts.byte> := [0, 0, 0, 0, 1, 0, 0, 0]
  // const MD_INIT_BLOCK: seq<BoundedInts.byte> := DuplicateSequenceRec([0, 0, 0, 0, 1, 0, 0, 0], METADATA_ENTRIES_PER_BLOCK as nat)

  // function DuplicateSequenceRec<T>(s: seq<T>, n: nat): seq<T>
  //   ensures |DuplicateSequenceRec(s, n)| == |s| * n
  //   ensures forall i :: 0 <= i < |DuplicateSequenceRec(s, n)| ==> DuplicateSequenceRec(s, n)[i] in s
  // {
  //   if n == 0 then []
  //   else s + DuplicateSequenceRec(s, n - 1)
  // }
}