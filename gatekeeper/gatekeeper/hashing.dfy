include "constants.dfy"
include "shared.dfy"

module Hashing {
  import HashingExterns
  import opened Shared
  import opened Wrappers
  import opened BoundedInts
  import opened Constants

  method HashBlock(bytes: BoundedInts.bytes, md: Shared.metadata_block_int, freshness_counter: BoundedInts.uint32) returns (hashblock_res: Result<(), string>)
  requires bytes.Length >= Constants.sizeof_hash_block_obj as nat
  {
    var isError := HashingExterns.INTERNAL_HashBlock(bytes, md, freshness_counter);
    return if isError then Failure("Error occured in internal impl call") else Success(());
  }

  method CheckHash(bytes: BoundedInts.bytes, offset: BoundedInts.uint32) returns (checkhash_res: Result<bool, string>)
    requires bytes.Length >= Constants.sizeof_hash_block_obj as nat
  {
    var isError, hash_eq := HashingExterns.INTERNAL_CheckHash(bytes, offset);
    return if isError then Failure("Error occured in internal impl call") else Success(hash_eq);
  }
}

module {:extern} {:compile false} HashingExterns {
  import opened BoundedInts
  import opened Shared

  method {:extern} INTERNAL_HashBlock(bytes: BoundedInts.bytes, md: Shared.metadata_block_int, freshness_counter: BoundedInts.uint32)
    returns (isError: bool)

  method {:extern} INTERNAL_CheckHash(bytes: BoundedInts.bytes, offset: BoundedInts.uint32)
    returns (isError: bool, hash_eq: bool)
}