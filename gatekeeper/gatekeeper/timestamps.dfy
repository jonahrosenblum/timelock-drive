include "constants.dfy"

module Timestamps {
  import TimestampInternalExterns
  import opened Wrappers
  import opened BoundedInts
  import opened Constants

  method ReadTimestamp() returns (timestamp_res: Result<BoundedInts.uint32, string>)
  {
    var isError, timestamp := TimestampInternalExterns.INTERNAL_ReadTimestamp();
    return if isError then Failure("Error occured in internal impl call") else Success(timestamp);
  }

  method ReadTimestamp64() returns (ts: BoundedInts.uint64)
    // ensures timestamp_res.Success? ==> timestamp_res.value >= old_timestamp
  {
    var isError, timestamp := TimestampInternalExterns.INTERNAL_ReadTimestamp64();
    expect !isError;
    return timestamp;
  }

}

module {:extern} {:compile false} TimestampInternalExterns {
  import opened BoundedInts

  method {:extern} INTERNAL_ReadTimestamp()
    returns (isError: bool, timestamp: BoundedInts.uint32)

  method {:extern} INTERNAL_ReadTimestamp64()
    returns (isError: bool, timestamp: BoundedInts.uint64)
}