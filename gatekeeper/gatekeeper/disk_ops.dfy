include "constants.dfy"
include "shared.dfy"
include "serialization-imperative.dfy"

module DiskOps {

  import opened Constants
  import opened Shared
  import opened Wrappers
  import opened DiskIOInternalExterns
  import opened Serialization_imperative

  method read_blocks(block_id: BoundedInts.uint32, num_blocks: BoundedInts.uint32, bytes: BoundedInts.bytes)
    requires block_id < Constants.TOTAL_DISK_BLOCKS
    requires bytes.Length >= Constants.BLOCK_SIZE as nat
    requires num_blocks > 0
    requires num_blocks as nat * Constants.BLOCK_SIZE as nat < BoundedInts.TWO_TO_THE_32
    requires (num_blocks * Constants.BLOCK_SIZE) as nat <= bytes.Length
  {
    var isError, errorMsg := DiskIOInternalExterns.INTERNAL_ReadBytesFromDisk(block_id, num_blocks, bytes);
    expect !isError, "Failed to read blocks: " + errorMsg;
  }

  method write_blocks(block_id: BoundedInts.uint32, num_blocks: BoundedInts.uint32, bytes: BoundedInts.bytes, bytes_offset: BoundedInts.uint32)
    requires block_id < Constants.TOTAL_DISK_BLOCKS
    requires bytes.Length >= Constants.BLOCK_SIZE as nat
    requires num_blocks > 0
    requires num_blocks as nat * Constants.BLOCK_SIZE as nat < BoundedInts.TWO_TO_THE_32
    requires (num_blocks * Constants.BLOCK_SIZE) as nat <= bytes.Length
  {
    var isError, errorMsg := DiskIOInternalExterns.INTERNAL_WriteBytesToDisk(block_id, num_blocks, bytes, bytes_offset);
    expect !isError, "Failed to write blocks: " + errorMsg;
  }

  method Sync() { var isError, errorMsg := DiskIOInternalExterns.INTERNAL_Sync(); expect !isError, "Failed to sync: " + errorMsg; }

  method PrintCounters() { DiskIOInternalExterns.INTERNAL_PrintCounters(); }

  method zero_out_blocks() {
    var zero_block := new BoundedInts.byte[Constants.BLOCK_SIZE](i => 0);

    // Reset known on-disk anchors so a fresh init does not chase stale log chains.
    var vmd_anchor := ((Constants.BLOCK_SIZE - (2 * Constants.sizeof_unsigned_int)) / (2 * Constants.sizeof_unsigned_int)) as BoundedInts.uint32;
    var hdmd_anchor := (Constants.TOTAL_NUM_MD_PER_LOG - 2) as BoundedInts.uint32;

    write_blocks(0, 1, zero_block, 0);
    write_blocks(vmd_anchor, 1, zero_block, 0);
    write_blocks(hdmd_anchor, 1, zero_block, 0);
    write_blocks(Constants.LOG_STATE_BLOCK, 1, zero_block, 0);
  }
}

module {:extern} {:compile false} DiskIOInternalExterns {
  import opened BoundedInts

  method {:extern} {:axiom} INTERNAL_ReadBytesFromDisk(block_id: BoundedInts.uint32, num_blocks: BoundedInts.uint32, bytes: BoundedInts.bytes)
    returns (isError: bool, errorMsg: string)

  method {:extern} INTERNAL_WriteBytesToDisk(block_id: BoundedInts.uint32, num_blocks: BoundedInts.uint32, bytes: BoundedInts.bytes, bytes_offset: BoundedInts.uint32)
    returns (isError: bool, errorMsg: string)

  method {:extern} INTERNAL_Sync()
    returns (isError: bool, errorMsg: string)

  method {:extern} INTERNAL_PrintCounters()
}
