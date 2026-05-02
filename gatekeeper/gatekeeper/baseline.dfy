include "std-library.dfy"
include "disk_ops.dfy"
include "interface.dfy"
include "serialization-imperative.dfy"

import opened Interface
import opened Serialization_imperative

class GatekeeperBaseline {
  constructor(port: BoundedInts.uint32, init_disk: bool, zero_first_block: bool)
  {
    print("RUNNING BASELINE");
    DiskOps.Sync();
    if (zero_first_block) {
      DiskOps.zero_out_blocks();
    }

    var interface_res: Wrappers.Result<(), string> := interface_init(port);
    expect interface_res.Success?, "Failed to initialize interface " + interface_res.error + "\n";
  }

  method send_response(bytes: BoundedInts.bytes, payload_size: BoundedInts.uint32)
  requires payload_size as nat <= bytes.Length
  {
    var send_res: Wrappers.Result<(), string> := Interface.interface_send(bytes, payload_size);
    expect send_res.Success?, "Failed to send response with error " + send_res.error + "\n";
  }

  method receive_incoming_request(bytes: BoundedInts.bytes, data_ranges: array<Shared.DataRange>)
    returns (ok: bool, header: Shared.DiskCmdHeader, write_payload_size: BoundedInts.uint32)
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    requires data_ranges.Length == Constants.MAX_MAPPING_COUNT as nat
  {
    var recv_res: Wrappers.Result<(), string>;
    recv_res, header, write_payload_size :=
      interface_receive_incoming_request(bytes, data_ranges);

    if (!recv_res.Success?) {
      return false, Shared.DiskCmdHeader(0, 0, Shared.InvalidCommand, 0), 0;
    }

    return true, header, write_payload_size;
  }

  method parse_requests()
  decreases *
  modifies this
  {
    var range_ := new Shared.DataRange();
    var data_ranges := new Shared.DataRange[Constants.MAX_MAPPING_COUNT](i => range_);

    for i: BoundedInts.uint32 := 0 to Constants.MAX_MAPPING_COUNT
      invariant i <= Constants.MAX_MAPPING_COUNT
      invariant forall j :: 0 <= j < i ==> fresh(data_ranges[j])
      invariant fresh(data_ranges)
    {
      data_ranges[i] := new Shared.DataRange();
    }

    ghost var data_ranges_snapshot := data_ranges[..];

    var bytes := new BoundedInts.byte[Constants.BUFFER_SIZE];
    var success_resp := new BoundedInts.byte[1](i => 0);
    var write_denied_resp := new BoundedInts.byte[1](i => 255);
    var evict_obj := new BoundedInts.byte[Constants.EVICT_OBJ_SIZE](i => 0);

    while true
      decreases *
      modifies this, bytes, evict_obj, data_ranges[..]
      invariant fresh(data_ranges)
      invariant fresh(bytes)
      invariant fresh(evict_obj)
    {
      var recv_ok: bool;
      var header: Shared.DiskCmdHeader;
      var write_payload_size: BoundedInts.uint32;
      recv_ok, header, write_payload_size := receive_incoming_request(bytes, data_ranges);
      if (!recv_ok) {
        // accept connection
        var request_res: Wrappers.Result<(), string> := interface_await_connection();
        expect request_res.Success?, "Interface connection failed " + request_res.error + "\n";
        continue;
      }

      var num_data_ranges: BoundedInts.uint32 := header.num_data_ranges as BoundedInts.uint32;

      expect 0 <= header.num_md_blocks as BoundedInts.uint32 <= Constants.MAX_MD_BLOCKS_IN_HEADER;
      expect (header.disk_cmd == Shared.Read || header.disk_cmd == Shared.Write) ==> 0 < header.num_data_ranges as BoundedInts.uint32 <= Constants.MAX_MAPPING_COUNT;

      match header.disk_cmd
      case Read =>
        handle_read(num_data_ranges, data_ranges, bytes);
      case Write =>
        var tot_blocks: BoundedInts.uint32 := 0;
        for i: BoundedInts.uint32 := 0 to num_data_ranges
        invariant i <= num_data_ranges
        {
          var blocks_i := data_ranges[i].num_blocks as BoundedInts.uint32;
          expect tot_blocks <= Constants.MAX_MAPPING_COUNT - blocks_i;
          tot_blocks := tot_blocks + blocks_i;
        }

        expect tot_blocks <= (Constants.MAX_MAPPING_COUNT), "Too many blocks found\n";
        var write_ok := handle_write(num_data_ranges, data_ranges, bytes);
        if (write_ok) {
          send_response(evict_obj, 1);
        } else {
          send_response(write_denied_resp, 1);
        }
      case Sync =>
        DiskOps.Sync();
        send_response(evict_obj, 1);
      case Finish =>
        send_response(success_resp, 1);
        break;
      case _ =>
        expect false, "Invalid disk command issued\n";
    }
  }

  method handle_read(num_data_ranges: BoundedInts.uint32, data_ranges: array<Shared.DataRange>, bytes: BoundedInts.bytes)
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    requires data_ranges.Length == Constants.MAX_MAPPING_COUNT as nat
    requires num_data_ranges <= data_ranges.Length as BoundedInts.uint32
    modifies bytes
  {
    for i: BoundedInts.uint32 := 0 to num_data_ranges
      invariant i <= num_data_ranges
    {
      var data_range := data_ranges[i];
      DiskOps.read_blocks(data_range.pba as BoundedInts.uint32, data_range.num_blocks as BoundedInts.uint32, bytes);
      send_response(bytes, data_range.num_blocks as BoundedInts.uint32 * Constants.BLOCK_SIZE);
    }
  }

  method handle_write(num_data_ranges: BoundedInts.uint32, data_ranges: array<Shared.DataRange>, bytes: BoundedInts.bytes) returns (write_ok: bool)
    requires data_ranges.Length == Constants.MAX_MAPPING_COUNT as nat
    requires 0 < num_data_ranges <= Constants.MAX_MAPPING_COUNT
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    ensures data_ranges[..] == old(data_ranges[..])
    
    modifies this
    modifies bytes
  {
    var bytes_offset: BoundedInts.uint32 := 0;
    for i: BoundedInts.uint32 := 0 to num_data_ranges
      invariant bytes_offset <= Constants.BUFFER_SIZE
      invariant bytes_offset % Constants.sizeof_unsigned_int == 0
    {
      var data_range := data_ranges[i];
      expect (data_range.pba as BoundedInts.uint32 + data_range.num_blocks as BoundedInts.uint32 <= Constants.TOTAL_DISK_BLOCKS && bytes_offset <= (Constants.BUFFER_SIZE - Constants.BLOCK_SIZE));
      expect bytes_offset <= Constants.BUFFER_SIZE - (data_range.num_blocks as BoundedInts.uint32 * Constants.BLOCK_SIZE);
      DiskOps.write_blocks(data_range.pba as BoundedInts.uint32, data_range.num_blocks as BoundedInts.uint32, bytes, bytes_offset);
      bytes_offset := bytes_offset + (data_range.num_blocks as BoundedInts.uint32 * Constants.BLOCK_SIZE);
      expect bytes_offset <= Constants.BUFFER_SIZE;
    }
    return true;
  }
}
