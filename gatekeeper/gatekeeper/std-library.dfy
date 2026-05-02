/*******************************************************************************
 *  Copyright by the contributors to the Dafny Project
 *  SPDX-License-Identifier: MIT
 *******************************************************************************/

module {:options "-functionSyntax:4"} BoundedInts {
  const TWO_TO_THE_0:   int := 1
  const TWO_TO_THE_1:   int := 2
  const TWO_TO_THE_2:   int := 4
  const TWO_TO_THE_4:   int := 16
  const TWO_TO_THE_5:   int := 32
  const TWO_TO_THE_8:   int := 256
  const TWO_TO_THE_16:  int := 65536
  const TWO_TO_THE_24:  int := 16777216
  const TWO_TO_THE_32:  int := 4294967296
  const TWO_TO_THE_40:  int := 1099511627776
  const TWO_TO_THE_41:  int := 2199023255552
  const TWO_TO_THE_48:  int := 281474976710656
  const TWO_TO_THE_56:  int := 72057594037927936
  const TWO_TO_THE_64:  int := 18446744073709551616
  const TWO_TO_THE_128: int := 340282366920938463463374607431768211456
  const TWO_TO_THE_256: int := 115792089237316195423570985008687907853269984665640564039457584007913129639936
  const TWO_TO_THE_512: int := 13407807929942597099574024998205846127479365820592393377723561443721764030073546976801874298166903427690031858186486050853753882811946569946433649006084096

  newtype bit = x: int | 0 <= x < TWO_TO_THE_1
  newtype uint8  = x: int | 0 <= x < TWO_TO_THE_8
  newtype uint16 = x: int | 0 <= x < TWO_TO_THE_16
  newtype uint32 = x: int | 0 <= x < TWO_TO_THE_32
  newtype uint41 = x: int | 0 <= x < TWO_TO_THE_41
  newtype uint64 = x: int | 0 <= x < TWO_TO_THE_64

  newtype int8  = x: int  | -0x80 <= x < 0x80
  newtype int16 = x: int  | -0x8000 <= x < 0x8000
  newtype int32 = x: int  | -0x8000_0000 <= x < 0x8000_0000
  newtype int64 = x: int  | -0x8000_0000_0000_0000 <= x < 0x8000_0000_0000_0000

  newtype nat8 = x: int   | 0 <= x < 0x80
  newtype nat16 = x: int  | 0 <= x < 0x8000
  newtype nat32 = x: int  | 0 <= x < 0x8000_0000
  newtype nat64 = x: int  | 0 <= x < 0x8000_0000_0000_0000

  const UINT8_MAX:  uint8  := 255
  const UINT16_MAX: uint16 := 65535
  const UINT32_MAX: uint32 := 4294967295
  const UINT64_MAX: uint64 := 18446744073709551615

  const INT8_MIN:  int8  := -128
  const INT8_MAX:  int8  :=  127
  const INT16_MIN: int16 := -32768
  const INT16_MAX: int16 :=  32767
  const INT32_MIN: int32 := -2147483648
  const INT32_MAX: int32 :=  2147483647
  const INT64_MIN: int64 := -9223372036854775808
  const INT64_MAX: int64 :=  9223372036854775807

  const NAT8_MAX:  nat8  := 127
  const NAT16_MAX: nat16 := 32767
  const NAT32_MAX: nat32 := 2147483647
  const NAT64_MAX: nat64 := 9223372036854775807

  type byte = uint8
  type bytes = array<byte>
  newtype opt_byte = c: int | -1 <= c < TWO_TO_THE_8
}

module Wrappers {
  /** A Success/Failure failure-compatible datatype that carries either a success value or an error value */
  datatype Result<+R, +E> = | Success(value: R) | Failure(error: E) {

    /** True if is Failure */
    predicate IsFailure() {
      Failure?
    }

    /** Returns the value encapsulated in Success */
    function Extract(): R
      requires Success?
    {
      value
    }
  }

  // A special case of Outcome that is just used for Need below, and
  // returns a Result<>
  datatype OutcomeResult<+E> = Pass' | Fail'(error: E) {
    predicate IsFailure() {
      Fail'?
    }
    function PropagateFailure<U>(): Result<U,E>
      requires IsFailure()
    {
      Failure(this.error)
    }
  }

  /** A helper function to ensure a requirement is true at runtime.
      Example: `:- Need(5 == |mySet|, "The set MUST have 5 elements.")`
  */
  function Need<E>(condition: bool, error: E): (result: OutcomeResult<E>)
  {
    if condition then Pass' else Fail'(error)
  }
}

// module DiskIO {
//   import DiskIOInternalExterns
//   import opened Wrappers
//   import opened BoundedInts

//   method ReadBytesFromDisk(block_id: BoundedInts.uint32, num_blocks: BoundedInts.uint32, bytes: BoundedInts.bytes) returns (res: Result<(), string>)
//   {
//     var isError, errorMsg := DiskIOInternalExterns.INTERNAL_ReadBytesFromDisk(block_id, num_blocks, bytes);
//     return if isError then Failure(errorMsg) else Success(());
//   }

//   method WriteBytesToDisk(block_id: BoundedInts.uint32, num_blocks: BoundedInts.uint32, bytes: BoundedInts.bytes) returns (res: Result<(), string>) {
//     // print(block_id); print(" ");
//     var isError, errorMsg := DiskIOInternalExterns.INTERNAL_WriteBytesToDisk(block_id, num_blocks, bytes);
//     return if isError then Failure(errorMsg) else Success(());
//   }

//   method Sync() returns (res: Result<(), string>) {
//     var isError, errorMsg := DiskIOInternalExterns.INTERNAL_Sync();
//     return if isError then Failure(errorMsg) else Success(());
//   }

//   method PrintCounters() {
//     DiskIOInternalExterns.INTERNAL_PrintCounters();
//   }
// }
