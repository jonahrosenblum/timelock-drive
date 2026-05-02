include "constants.dfy"
include "shared.dfy"

module AbstractTimelock {
  import opened BoundedInts

  datatype TimelockState = Free | FrozenTimelock | CountdownTimelock

  function AbstractTimelockNext(ts: TimelockState): TimelockState { match ts case Free => FrozenTimelock case FrozenTimelock => CountdownTimelock case CountdownTimelock => Free }
}

// Concrete specification
module {:options "-functionSyntax:3"} ConcreteTimelock {
  import opened AbstractTimelock
  import BoundedInts

  datatype TimelockMetadataEncoding = TimelockMetadataEncoding(keep_duration : BoundedInts.uint32, time_written : BoundedInts.uint32)

  predicate method IsFree(e: TimelockMetadataEncoding, current_time: BoundedInts.uint32)
  {
    && e.time_written % 2 == 1
    && current_time > e.keep_duration
  }

  predicate method IsFrozenTimelock(e: TimelockMetadataEncoding) { e.time_written % 2 == 0 }

  predicate method ValidDeadline(e: TimelockMetadataEncoding, current_time: BoundedInts.uint32) { e.keep_duration <= BoundedInts.UINT32_MAX - current_time }

  predicate method IsCountdownTimelock(e: TimelockMetadataEncoding, current_time: BoundedInts.uint32)
  {
    && e.time_written % 2 == 1
    && current_time <= e.keep_duration
  }

  function method ConcreteTimelockNext(e: TimelockMetadataEncoding, keep_duration: BoundedInts.uint32, current_time: BoundedInts.uint32): TimelockMetadataEncoding
    requires ValidDeadline(e, current_time)
  {
    if IsFree(e, current_time) then
      TimelockMetadataEncoding(keep_duration, if current_time % 2 == 0 then current_time else current_time - 1)
    else if IsFrozenTimelock(e) then
      TimelockMetadataEncoding(e.keep_duration + current_time, e.time_written + 1)
    else
      assert IsCountdownTimelock(e, current_time);
      assert e.time_written % 2 == 1;
      e
  }

  // Refinement mapping (concrete metadata encoding to abstract Timelock states)
  function Refine(e: TimelockMetadataEncoding, current_time: BoundedInts.uint32): TimelockState
  {
    if IsFree(e, current_time) then Free
    else if IsFrozenTimelock(e) then FrozenTimelock
    else
      assert IsCountdownTimelock(e, current_time);
      CountdownTimelock
  }
}

module {:options "-functionSyntax:3"} ByteLevelTimelock {
  import opened AbstractTimelock
  import opened BoundedInts
  import ConcreteTimelock
  import Constants

  module ByteConversionConstants {
    import opened BoundedInts
    const BYTE_SHIFT_0: BoundedInts.uint32 := 1
    const BYTE_SHIFT_1: BoundedInts.uint32 := 256
    const BYTE_SHIFT_2: BoundedInts.uint32 := BYTE_SHIFT_1 * BYTE_SHIFT_1
    const BYTE_SHIFT_3: BoundedInts.uint32 := BYTE_SHIFT_2 * BYTE_SHIFT_1
  }

  predicate method converts_to_uint32(bytes_length: BoundedInts.uint32, offset: BoundedInts.uint32) {
    (bytes_length > 0 && (bytes_length % Constants.sizeof_unsigned_int) == 0) && (offset % Constants.sizeof_unsigned_int == 0)
  }

  function method arr_bytes_to_uint32(bytes: array<BoundedInts.byte>, offset: BoundedInts.uint32) : BoundedInts.uint32
    requires (bytes.Length > 0 && (bytes.Length % Constants.sizeof_unsigned_int as nat) == 0)
    requires (offset % Constants.sizeof_unsigned_int == 0)
    requires (offset as nat + Constants.sizeof_unsigned_int as nat) <= bytes.Length
    reads bytes
  {
    (bytes[offset + 3] as BoundedInts.uint32 * ByteConversionConstants.BYTE_SHIFT_3) +
    (bytes[offset + 2] as BoundedInts.uint32 * ByteConversionConstants.BYTE_SHIFT_2) +
    (bytes[offset + 1] as BoundedInts.uint32 * ByteConversionConstants.BYTE_SHIFT_1) +
    (bytes[offset + 0] as BoundedInts.uint32)
  }

  function method uint32_to_bytes(ui: BoundedInts.uint32) : seq<BoundedInts.byte>
    ensures |uint32_to_bytes(ui)| == Constants.sizeof_unsigned_int as nat
  {
    [
      (ui % ByteConversionConstants.BYTE_SHIFT_1) as BoundedInts.byte,
      ((ui / ByteConversionConstants.BYTE_SHIFT_1) % ByteConversionConstants.BYTE_SHIFT_1) as BoundedInts.byte,
      ((ui / ByteConversionConstants.BYTE_SHIFT_2) % ByteConversionConstants.BYTE_SHIFT_1) as BoundedInts.byte,
      ((ui / ByteConversionConstants.BYTE_SHIFT_3) % ByteConversionConstants.BYTE_SHIFT_1) as BoundedInts.byte
    ]
  }

  // Constants for byte offsets
  const KEEP_DURATION_OFFSET: BoundedInts.uint32 := 0
  const TIME_WRITTEN_OFFSET: BoundedInts.uint32 := Constants.sizeof_unsigned_int
  const METADATA_SIZE: BoundedInts.uint32 := Constants.sizeof_unsigned_int + Constants.sizeof_unsigned_int

  predicate no_overflow(bytes_length: BoundedInts.uint32, offset: BoundedInts.uint32)
  {
    && offset as nat + Constants.sizeof_unsigned_int as nat < BoundedInts.TWO_TO_THE_32 as nat
    && offset as nat + Constants.sizeof_unsigned_int as nat <= bytes_length as nat
  }

  // Check if a uint32 (represented as 4 bytes) is odd by checking the LSB
  function method IsOddBytes(bytes: BoundedInts.bytes, offset: BoundedInts.uint32): bool
    requires bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(bytes.Length as BoundedInts.uint32, offset)
    reads bytes
  {
    bytes[offset] % 2 == 1
  }

  // Check if a uint32 (represented as 4 bytes) is even
  function method IsEvenBytes(bytes: BoundedInts.bytes, offset: BoundedInts.uint32): bool
    requires bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(bytes.Length as BoundedInts.uint32, offset)
    reads bytes
  {
    bytes[offset] % 2 == 0
  }

  // Compare two uint32 values represented as bytes: a > b
  // Big-endian comparison (compare from most significant byte)
  function method GreaterThanBytes(a_bytes: BoundedInts.bytes, a_offset: BoundedInts.uint32, b_bytes: BoundedInts.bytes, b_offset: BoundedInts.uint32): bool
    requires a_bytes != b_bytes
    requires a_bytes != b_bytes
    requires a_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires b_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(a_bytes.Length as BoundedInts.uint32, a_offset)
    requires no_overflow(b_bytes.Length as BoundedInts.uint32, b_offset)
    reads a_bytes, b_bytes
  {
    // Compare byte by byte from most significant (offset+3) to least significant (offset+0)
    if a_bytes[a_offset + 3] != b_bytes[b_offset + 3] then
      a_bytes[a_offset + 3] > b_bytes[b_offset + 3]
    else if a_bytes[a_offset + 2] != b_bytes[b_offset + 2] then
      a_bytes[a_offset + 2] > b_bytes[b_offset + 2]
    else if a_bytes[a_offset + 1] != b_bytes[b_offset + 1] then
      a_bytes[a_offset + 1] > b_bytes[b_offset + 1]
    else
      a_bytes[a_offset + 0] > b_bytes[b_offset + 0]
  }

  // Check if adding two uint32s (as bytes) would overflow
  // This requires checking if keep_duration + current_time < 2^32
  function method WouldOverflowBytes(a_bytes: BoundedInts.bytes, a_offset: BoundedInts.uint32, b_bytes: BoundedInts.bytes, b_offset: BoundedInts.uint32): bool
    requires a_bytes != b_bytes
    requires a_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(a_bytes.Length as BoundedInts.uint32, a_offset)

    requires b_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(b_bytes.Length as BoundedInts.uint32, b_offset)
    requires converts_to_uint32(a_bytes.Length as BoundedInts.uint32, a_offset)
    requires converts_to_uint32(b_bytes.Length as BoundedInts.uint32, b_offset)
    ensures var a := arr_bytes_to_uint32(a_bytes, a_offset);
            var b := arr_bytes_to_uint32(b_bytes, b_offset);
            WouldOverflowBytes(a_bytes, a_offset, b_bytes, b_offset) ==> (a as nat + b as nat) > BoundedInts.TWO_TO_THE_32
    reads a_bytes, b_bytes
  {
    // Check for overflow by performing byte-wise addition with carry
    var carry0 := (a_bytes[a_offset] as BoundedInts.uint32 + b_bytes[b_offset] as BoundedInts.uint32) / 256;
    var carry1 := (a_bytes[a_offset + 1] as BoundedInts.uint32 + b_bytes[b_offset + 1] as BoundedInts.uint32 + carry0) / 256;
    var carry2 := (a_bytes[a_offset + 2] as BoundedInts.uint32 + b_bytes[b_offset + 2] as BoundedInts.uint32 + carry1) / 256;
    var carry3 := (a_bytes[a_offset + 3] as BoundedInts.uint32 + b_bytes[b_offset + 3] as BoundedInts.uint32 + carry2) / 256;
    carry3 > 0
  }

  // Add two uint32s represented as bytes, storing result in a_bytes
  method AddUint32Bytes(a_bytes: BoundedInts.bytes, a_offset: BoundedInts.uint32, b_bytes: BoundedInts.bytes, b_offset: BoundedInts.uint32)
    requires a_bytes != b_bytes
    requires a_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(a_bytes.Length as BoundedInts.uint32, a_offset)

    requires b_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(b_bytes.Length as BoundedInts.uint32, b_offset)
    requires converts_to_uint32(a_bytes.Length as BoundedInts.uint32, a_offset)
    requires converts_to_uint32(b_bytes.Length as BoundedInts.uint32, b_offset)
    requires !WouldOverflowBytes(a_bytes, a_offset, b_bytes, b_offset)
    // ensures !WouldOverflowBytes(a_bytes, a_offset, b_bytes, b_offset)
    ensures var a := old(arr_bytes_to_uint32(a_bytes, a_offset));
            var b := arr_bytes_to_uint32(b_bytes, b_offset);
            (a as nat + b as nat) < BoundedInts.TWO_TO_THE_32 // no overflow happened
    ensures var a := old(arr_bytes_to_uint32(a_bytes, a_offset));
            var b := arr_bytes_to_uint32(b_bytes, b_offset);
            var c := a + b;
            arr_bytes_to_uint32(a_bytes, a_offset) == c
    ensures forall i :: 0 <= i < a_offset as nat || (a_offset + Constants.sizeof_unsigned_int) as nat <= i < a_bytes.Length ==> a_bytes[i] == old(a_bytes[i])
    modifies a_bytes
  {
    var sum0 := a_bytes[a_offset + 0] as BoundedInts.uint32 + b_bytes[b_offset + 0] as BoundedInts.uint32;
    a_bytes[a_offset + 0] := (sum0 % ByteConversionConstants.BYTE_SHIFT_1) as byte;
    var carry0 := sum0 / ByteConversionConstants.BYTE_SHIFT_1;

    var sum1 := a_bytes[a_offset + 1] as BoundedInts.uint32 + b_bytes[b_offset + 1] as BoundedInts.uint32+ carry0;
    a_bytes[a_offset + 1] := (sum1 % ByteConversionConstants.BYTE_SHIFT_1) as byte;
    var carry1 := sum1 / ByteConversionConstants.BYTE_SHIFT_1;

    var sum2 := a_bytes[a_offset + 2] as BoundedInts.uint32 + b_bytes[b_offset + 2] as BoundedInts.uint32 + carry1;
    a_bytes[a_offset + 2] := (sum2 % ByteConversionConstants.BYTE_SHIFT_1) as byte;
    var carry2 := sum2 / ByteConversionConstants.BYTE_SHIFT_1;

    var sum3 := a_bytes[a_offset + 3] as BoundedInts.uint32 + b_bytes[b_offset + 3] as BoundedInts.uint32 + carry2;
    a_bytes[a_offset + 3] := (sum3 % ByteConversionConstants.BYTE_SHIFT_1) as byte;
  }

  // Byte-level predicates
  function method IsFreeBytes(metadata: BoundedInts.bytes, metadata_offset: BoundedInts.uint32, current_time_bytes: BoundedInts.bytes, current_time_offset: BoundedInts.uint32): bool
    requires metadata != current_time_bytes
    requires metadata.Length == Constants.sizeof_hash_block_obj as nat
    requires metadata_offset % Constants.sizeof_MetadataEntry == 0
    requires metadata.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(metadata.Length as BoundedInts.uint32, metadata_offset)

    requires current_time_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    requires (metadata_offset as nat + TIME_WRITTEN_OFFSET as nat) < BoundedInts.TWO_TO_THE_32
    requires no_overflow(metadata.Length as BoundedInts.uint32, metadata_offset + TIME_WRITTEN_OFFSET)
    requires no_overflow(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    requires converts_to_uint32(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    ensures var keep_duration := arr_bytes_to_uint32(metadata, metadata_offset + KEEP_DURATION_OFFSET);
            var time_written := arr_bytes_to_uint32(metadata, metadata_offset + TIME_WRITTEN_OFFSET);
            var current_time := arr_bytes_to_uint32(current_time_bytes, current_time_offset);
            var e := ConcreteTimelock.TimelockMetadataEncoding(keep_duration, time_written);
            && (IsFreeBytes(metadata, metadata_offset, current_time_bytes, current_time_offset) ==> ConcreteTimelock.IsFree(e, current_time))
            && (ConcreteTimelock.IsFree(e, current_time) ==> IsFreeBytes(metadata, metadata_offset, current_time_bytes, current_time_offset))
    reads metadata, current_time_bytes
  {
    && IsOddBytes(metadata, metadata_offset + 4)
    && GreaterThanBytes(current_time_bytes, current_time_offset, metadata, metadata_offset)
  }

  function method IsFrozenTimelockBytes(metadata: BoundedInts.bytes, metadata_offset: BoundedInts.uint32): bool
    requires metadata.Length == Constants.sizeof_hash_block_obj as nat
    requires metadata_offset % Constants.sizeof_MetadataEntry == 0
    requires (metadata_offset as nat + TIME_WRITTEN_OFFSET as nat) < BoundedInts.TWO_TO_THE_32
    requires no_overflow(metadata.Length as BoundedInts.uint32, metadata_offset + TIME_WRITTEN_OFFSET)
    ensures var keep_duration := arr_bytes_to_uint32(metadata, metadata_offset + KEEP_DURATION_OFFSET);
            var time_written := arr_bytes_to_uint32(metadata, metadata_offset + TIME_WRITTEN_OFFSET);
            var e := ConcreteTimelock.TimelockMetadataEncoding(keep_duration, time_written);
            && (IsFrozenTimelockBytes(metadata, metadata_offset) ==> ConcreteTimelock.IsFrozenTimelock(e))
            && (ConcreteTimelock.IsFrozenTimelock(e) ==> IsFrozenTimelockBytes(metadata, metadata_offset))
    reads metadata
  {
    IsEvenBytes(metadata, metadata_offset + TIME_WRITTEN_OFFSET)
  }

  function method IsCountdownTimelockBytes(metadata: BoundedInts.bytes, metadata_offset: BoundedInts.uint32, current_time_bytes: BoundedInts.bytes, current_time_offset: BoundedInts.uint32): bool
    requires metadata != current_time_bytes
    requires metadata.Length == Constants.sizeof_hash_block_obj as nat
    requires metadata_offset % Constants.sizeof_MetadataEntry == 0
    requires (metadata_offset as nat + TIME_WRITTEN_OFFSET as nat) < BoundedInts.TWO_TO_THE_32
    requires no_overflow(metadata.Length as BoundedInts.uint32, metadata_offset + TIME_WRITTEN_OFFSET)
    requires current_time_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    requires converts_to_uint32(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    ensures var keep_duration := arr_bytes_to_uint32(metadata, metadata_offset + KEEP_DURATION_OFFSET);
            var time_written := arr_bytes_to_uint32(metadata, metadata_offset + TIME_WRITTEN_OFFSET);
            var current_time := arr_bytes_to_uint32(current_time_bytes, current_time_offset);
            var e := ConcreteTimelock.TimelockMetadataEncoding(keep_duration, time_written);
            && (IsCountdownTimelockBytes(metadata, metadata_offset, current_time_bytes, current_time_offset) ==> ConcreteTimelock.IsCountdownTimelock(e, current_time))
            && (ConcreteTimelock.IsCountdownTimelock(e, current_time) ==> IsCountdownTimelockBytes(metadata, metadata_offset, current_time_bytes, current_time_offset))
    reads metadata, current_time_bytes
  {
    && IsOddBytes(metadata, metadata_offset + TIME_WRITTEN_OFFSET)
    && !GreaterThanBytes(current_time_bytes, current_time_offset, metadata, metadata_offset + KEEP_DURATION_OFFSET)
  }

  // Write 4 bytes into metadata at given offset
  method WriteUint32Bytes(metadata: BoundedInts.bytes, metadata_offset: BoundedInts.uint32, value_bytes: BoundedInts.bytes, value_offset: BoundedInts.uint32)
    requires metadata != value_bytes
    requires metadata.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(metadata.Length as BoundedInts.uint32, metadata_offset)
    requires value_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(value_bytes.Length as BoundedInts.uint32, value_offset)
    ensures forall i :: 0 <= i < metadata_offset as nat || (metadata_offset + Constants.sizeof_unsigned_int) as nat <= i < metadata.Length ==> metadata[i] == old(metadata[i])
    ensures metadata[metadata_offset + 0] == value_bytes[value_offset + 0]
    ensures metadata[metadata_offset + 1] == value_bytes[value_offset + 1]
    ensures metadata[metadata_offset + 2] == value_bytes[value_offset + 2]
    ensures metadata[metadata_offset + 3] == value_bytes[value_offset + 3]
    modifies metadata
  {
    metadata[metadata_offset + 0] := value_bytes[value_offset + 0];
    metadata[metadata_offset + 1] := value_bytes[value_offset + 1];
    metadata[metadata_offset + 2] := value_bytes[value_offset + 2];
    metadata[metadata_offset + 3] := value_bytes[value_offset + 3];
  }

  // Byte-level state transition
  method ByteLevelTimelockNext(
    metadata: BoundedInts.bytes,
    metadata_offset: BoundedInts.uint32,
    keep_duration_bytes: BoundedInts.bytes,
    keep_duration_offset: BoundedInts.uint32,
    current_time_bytes: BoundedInts.bytes,
    current_time_offset: BoundedInts.uint32
  )
    requires metadata != keep_duration_bytes && metadata != current_time_bytes //&& keep_duration_bytes != current_time_bytes
    requires metadata.Length == Constants.sizeof_hash_block_obj as nat
    requires metadata_offset % Constants.sizeof_MetadataEntry == 0
    requires (metadata_offset as nat + TIME_WRITTEN_OFFSET as nat) < BoundedInts.TWO_TO_THE_32
    requires no_overflow(metadata.Length as BoundedInts.uint32, metadata_offset + TIME_WRITTEN_OFFSET)
    requires current_time_bytes.Length > 0 && current_time_bytes.Length % Constants.sizeof_unsigned_int as nat == 0
    requires keep_duration_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(keep_duration_bytes.Length as BoundedInts.uint32, keep_duration_offset)
    requires current_time_bytes.Length < BoundedInts.TWO_TO_THE_32
    requires no_overflow(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    requires converts_to_uint32(metadata.Length as BoundedInts.uint32, metadata_offset)
    requires converts_to_uint32(current_time_bytes.Length as BoundedInts.uint32, current_time_offset)
    requires converts_to_uint32(keep_duration_bytes.Length as BoundedInts.uint32, keep_duration_offset)
    requires !WouldOverflowBytes(metadata, metadata_offset + KEEP_DURATION_OFFSET, current_time_bytes, current_time_offset)
    ensures forall i :: 0 <= i < metadata_offset as nat || (metadata_offset + Constants.sizeof_MetadataEntry) as nat <= i < metadata.Length ==> metadata[i] == old(metadata[i])
    ensures var keep_duration_e := old(arr_bytes_to_uint32(metadata, metadata_offset + KEEP_DURATION_OFFSET));
            var time_written_e := old(arr_bytes_to_uint32(metadata, metadata_offset + TIME_WRITTEN_OFFSET));
            var keep_duration_e' := arr_bytes_to_uint32(metadata, metadata_offset + KEEP_DURATION_OFFSET);
            var time_written_e' := arr_bytes_to_uint32(metadata, metadata_offset + TIME_WRITTEN_OFFSET);
            
            var current_time := arr_bytes_to_uint32(current_time_bytes, current_time_offset);
            var keep_duration := arr_bytes_to_uint32(keep_duration_bytes, keep_duration_offset);

            var e := ConcreteTimelock.TimelockMetadataEncoding(keep_duration_e, time_written_e);
            var e' := ConcreteTimelock.ConcreteTimelockNext(e, keep_duration, current_time);
            e' == ConcreteTimelock.TimelockMetadataEncoding(keep_duration_e', time_written_e')
    modifies metadata
  {
    ghost var keep_duration_e := arr_bytes_to_uint32(metadata, metadata_offset + KEEP_DURATION_OFFSET);
    ghost var time_written_e := arr_bytes_to_uint32(metadata, metadata_offset + TIME_WRITTEN_OFFSET);
    ghost var current_time := arr_bytes_to_uint32(current_time_bytes, current_time_offset);
    ghost var e := ConcreteTimelock.TimelockMetadataEncoding(keep_duration_e, time_written_e);

    if IsFreeBytes(metadata, metadata_offset, current_time_bytes, current_time_offset) {
      assert ConcreteTimelock.IsFree(e, current_time);
      WriteUint32Bytes(metadata, metadata_offset + KEEP_DURATION_OFFSET, keep_duration_bytes, keep_duration_offset);
      WriteUint32Bytes(metadata, metadata_offset + TIME_WRITTEN_OFFSET, current_time_bytes, current_time_offset);
      if IsOddBytes(metadata, metadata_offset + 4) {
        assert current_time % 2 == 1;
        // Subtract one from most least significant digit to make sure our time is even
        metadata[metadata_offset + 4] := metadata[metadata_offset + 4] - 1;
      }
    }
    else if IsFrozenTimelockBytes(metadata, metadata_offset)
    {
      // Start the countdown based on our current time and the keep duration
      AddUint32Bytes(metadata, metadata_offset, current_time_bytes, current_time_offset);
      // Add one from most least significant digit to make sure our time is odd
      metadata[metadata_offset + 4] := metadata[metadata_offset + 4] + 1;
    }
    else {
      assert IsCountdownTimelockBytes(metadata, metadata_offset, current_time_bytes, current_time_offset);
    }
  }
}

module TimelockRefinement {
  import opened AbstractTimelock
  import opened ConcreteTimelock
  import opened BoundedInts

  // Main refinement theorem
  lemma RefinementTheorem(
    e: TimelockMetadataEncoding,
    keep_duration: BoundedInts.uint32,
    current_time: BoundedInts.uint32,
    future_time: BoundedInts.uint32
  )

    // Preconditions for valid transitions
    requires ValidDeadline(e, current_time)
    requires future_time > e.keep_duration
    ensures
      // If we are currently in countdown timelock, I need a future time that represents the
      // "time has passed" state transition for the Refine step! Otherwise we will just stay
      // in the countdown state. If I always use the future time then the Frozen state will
      // automatically transition to Free, hence the control flow based on current state.
      var time' := if IsCountdownTimelock(e, current_time) then future_time else current_time;
      var concrete_e' := ConcreteTimelockNext(e, keep_duration, current_time);
      var abstract_e := Refine(e, current_time);
      var abstract_e' := AbstractTimelockNext(abstract_e);
      && Refine(concrete_e', time') == abstract_e'
  {
  }

}
