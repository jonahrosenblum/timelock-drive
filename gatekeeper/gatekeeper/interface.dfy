include "std-library.dfy"
include "constants.dfy"
include "shared.dfy"

module Interface {
  import opened InterfaceInternalExterns
  import opened BoundedInts
  import opened Wrappers
  import opened Constants
  import opened Shared

  method interface_init(port: BoundedInts.uint32) returns (res: Result<(), string>)
  {
    var isError: bool, errorMsg: string := InterfaceInternalExterns.INTERNAL_interface_init(port);
    return if isError then Failure(errorMsg) else Success(());
  }

  method interface_set_ipc_mode(enable: bool)
  { InterfaceInternalExterns.INTERNAL_interface_set_ipc_mode(enable); }

  method interface_await_connection() returns (res: Result<(), string>)
  {
    var isError: bool, errorMsg: string := InterfaceInternalExterns.INTERNAL_interface_await_connection();
    return if isError then Failure(errorMsg) else Success(());
  }

  method interface_receive(bytes: array<byte>, size: BoundedInts.uint32) returns (res: Result<(), string>)
  requires size as nat <= bytes.Length
  {
    var isError: bool, errorMsg: string := InterfaceInternalExterns.INTERNAL_interface_receive(bytes, size);
    return if isError then Failure(errorMsg) else Success(());
  }

  method interface_send(payload: array<byte>, size: BoundedInts.uint32) returns (res: Result<(), string>)
  requires size as nat <= payload.Length
  {
    var isError: bool, errorMsg: string := InterfaceInternalExterns.INTERNAL_interface_send(payload, size);
    return if isError then Failure(errorMsg) else Success(());
  }

  method interface_receive_incoming_request(bytes: array<byte>, data_ranges: array<Shared.DataRange>)
    returns (
      res: Result<(), string>,
      header: Shared.DiskCmdHeader,
      write_payload_size: BoundedInts.uint32)
    requires bytes.Length >= Constants.BUFFER_SIZE as nat
    requires data_ranges.Length == Constants.MAX_MAPPING_COUNT as nat
  {
    var isError: bool, errorMsg: string,
        out_header: Shared.DiskCmdHeader,
        out_write_payload_size: BoundedInts.uint32
      := InterfaceInternalExterns.INTERNAL_receive_incoming_request(bytes, data_ranges);

    header := out_header;
    write_payload_size := out_write_payload_size;
    res := if isError then Failure(errorMsg) else Success(());
  }
}

module {:extern} {:compile false} InterfaceInternalExterns {
  import opened BoundedInts
  import opened Shared

  method {:extern} INTERNAL_interface_init(port: BoundedInts.uint32)
    returns (isError: bool, errorMsg: string)

  method {:extern} INTERNAL_interface_set_ipc_mode(enable: bool)

  method {:extern} INTERNAL_interface_await_connection()
    returns (isError: bool, errorMsg: string)

  method {:extern} {:axiom} INTERNAL_interface_receive(block: array<BoundedInts.byte>, size: BoundedInts.uint32)
    returns (isError: bool, errorMsg: string)

  method {:extern} {:axiom} INTERNAL_receive_incoming_request(block: array<BoundedInts.byte>, data_ranges: array<Shared.DataRange>)
    returns (
      isError: bool,
      errorMsg: string,
      header: Shared.DiskCmdHeader,
      write_payload_size: BoundedInts.uint32)

  method {:extern} INTERNAL_interface_send(payload: array<byte>, size: BoundedInts.uint32)
    returns (isError: bool, errorMsg: string)
}