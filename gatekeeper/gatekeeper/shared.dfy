include "constants.dfy"

module {:options "-functionSyntax:3"} Shared {
  import opened BoundedInts
  import opened Constants
  import SharedInternalExterns

  datatype DiskCommand = Read | Write | Sync | InitCounters | Finish | Identify | InvalidCommand // Finish is just for evaluation purposes
  datatype DiskCmdHeader = DiskCmdHeader(num_data_ranges: BoundedInts.uint8, num_md_blocks: BoundedInts.uint8, disk_cmd : DiskCommand, payload_size: BoundedInts.uint32)
  newtype physical_block_address = x: BoundedInts.uint32 | x < Constants.TOTAL_DISK_BLOCKS
  newtype metadata_block_int = x: BoundedInts.uint32 | x < Constants.TOTAL_NUM_METADATA_BLOCKS witness 0
  newtype td_cache_idx_int = x: BoundedInts.uint32 | x < Constants.MAX_TD_CACHE_SIZE
  newtype num_blocks_int = x: BoundedInts.uint32 | 0 < x <= Constants.MAX_MAPPING_COUNT as BoundedInts.uint32 witness 1
  newtype block_offset_int = x: BoundedInts.uint32 | x < Constants.METADATA_ENTRIES_PER_BLOCK

  type BLOCK = x: seq<byte> | |x| == BLOCK_SIZE as nat witness seq(Constants.BLOCK_SIZE, i => 0)
  type HASH_BLOCK = x: seq<byte> | |x| == sizeof_hash_block_obj as nat witness seq(sizeof_hash_block_obj, i => 0)
  
  class DataRange {
    var pba: physical_block_address
    var num_blocks: num_blocks_int
    constructor() { pba := 0; num_blocks := 1; }
  }

  function method Byte_to_DiskCommand(byte: BoundedInts.byte) : DiskCommand {
    match byte
    case 0 => Read
    case 1 => Write
    case 2 => Sync
    case 3 => InitCounters
    case 4 => Finish
    case 8 => Identify
    case _ => InvalidCommand
  }

  method copy_array(a: array<BoundedInts.byte>, a_offset: BoundedInts.uint32, b: array<BoundedInts.byte>, b_offset: BoundedInts.uint32)
    requires a.Length >= Constants.sizeof_hash_block_obj as nat
    requires a_offset as nat + Constants.sizeof_hash_block_obj as nat < BoundedInts.TWO_TO_THE_32
    requires (a_offset + Constants.sizeof_hash_block_obj) as nat <= a.Length
    requires b.Length >= Constants.sizeof_hash_block_obj as nat
    requires b_offset as nat + Constants.sizeof_hash_block_obj as nat < BoundedInts.TWO_TO_THE_32
    requires (b_offset + Constants.sizeof_hash_block_obj) as nat <= b.Length
    // ensures forall j | 0 <= j < Constants.sizeof_hash_block_obj :: a[j + a_offset] == b[j]
    modifies a
  {
    SharedInternalExterns.INTERNAL_copy_array(a, a_offset, b, b_offset, Constants.sizeof_hash_block_obj);
  }

  function method pba_to_md_and_offset(pba: physical_block_address) : (metadata_block_int, block_offset_int) {
    (((pba as BoundedInts.uint32 / Constants.METADATA_ENTRIES_PER_BLOCK) as metadata_block_int), ((pba as BoundedInts.uint32 % Constants.METADATA_ENTRIES_PER_BLOCK) as block_offset_int))
  }

  method find_needle_in_haystack<T(==)>(arr: array<T>, scan_len: BoundedInts.uint32, needle: T) returns (found: bool, idx: BoundedInts.uint32)
    requires scan_len as nat <= arr.Length <= BoundedInts.UINT32_MAX as nat
    ensures found ==> idx < scan_len
    ensures found ==> arr[idx] == needle
    ensures found ==> forall j: BoundedInts.uint32 :: j < idx ==> arr[j] != needle
    ensures !found ==> idx == 0
    ensures !found ==> forall j: BoundedInts.uint32 :: j < scan_len ==> arr[j] != needle
  {
    for i: BoundedInts.uint32 := 0 to scan_len
      invariant i <= scan_len
      invariant forall j: BoundedInts.uint32 :: j < i ==> arr[j] != needle
    {
      if (arr[i] == needle) { return true, i; }
    }
    return false, 0;
  }
}

module {:extern} {:compile false} SharedInternalExterns {
  import opened BoundedInts

  method {:extern} INTERNAL_copy_array(a: BoundedInts.bytes, a_offset: BoundedInts.uint32, b: BoundedInts.bytes, b_offset: BoundedInts.uint32, size: BoundedInts.uint32)
}
