include "constants.dfy"
include "shared.dfy"
include "timelock.dfy"

module {:options "--function-syntax:3"} Serialization_imperative {

  import opened Constants
  import opened BoundedInts
  import opened Shared

  module ByteConversionConstants {
    import opened BoundedInts
    const BYTE_SHIFT_0: BoundedInts.uint32 := 1
    const BYTE_SHIFT_1: BoundedInts.uint32 := 256
    const BYTE_SHIFT_2: BoundedInts.uint32 := BYTE_SHIFT_1 * BYTE_SHIFT_1
    const BYTE_SHIFT_3: BoundedInts.uint32 := BYTE_SHIFT_2 * BYTE_SHIFT_1
  }

  function method bytes_to_uint32(bytes: BoundedInts.bytes, offset: BoundedInts.uint32) : BoundedInts.uint32
    requires bytes.Length >= Constants.sizeof_unsigned_int as nat
    requires (offset as nat + Constants.sizeof_unsigned_int as nat) < BoundedInts.TWO_TO_THE_32
    requires (offset + Constants.sizeof_unsigned_int) as nat <= bytes.Length
    requires (offset as nat + Constants.sizeof_unsigned_int as nat) <= bytes.Length
    reads bytes
  {
    (bytes[offset + 3] as BoundedInts.uint32 * 16777216) + (bytes[offset + 2] as BoundedInts.uint32 * 65536) + (bytes[offset + 1] as BoundedInts.uint32 * 256) + (bytes[offset + 0] as BoundedInts.uint32)
  }

  // Little endian system!
  method uint32_to_bytes(val: BoundedInts.uint32, bytes: BoundedInts.bytes, offset: BoundedInts.uint32)
    requires bytes.Length > 0
    requires offset as nat + bytes.Length < BoundedInts.TWO_TO_THE_32
    requires (offset as nat + Constants.sizeof_unsigned_int as nat) <= bytes.Length
    ensures forall i | 0 <= i < bytes.Length && !(offset as nat <= i < (offset as nat + Constants.sizeof_unsigned_int as nat)) :: bytes[i] == old(bytes[i])
    modifies bytes
  {
    var mutable_val: BoundedInts.uint32 := val;
    bytes[offset + 0] := (mutable_val % 256) as BoundedInts.byte;
    mutable_val := (mutable_val / 256);

    bytes[offset + 1] := (mutable_val % 256) as BoundedInts.byte;
    mutable_val := (mutable_val / 256);

    bytes[offset + 2] := (mutable_val % 256) as BoundedInts.byte;
    mutable_val := (mutable_val / 256);

    bytes[offset + 3] := (mutable_val % 256) as BoundedInts.byte;

    assert forall i | 0 <= i < bytes.Length && !(offset as nat <= i <= (offset + 3) as nat) :: bytes[i] == old(bytes[i]);
  }

}