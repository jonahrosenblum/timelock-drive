include "std-library.dfy"
include "timestamps.dfy"
include "disk_ops.dfy"
include "interface.dfy"
include "serialization-imperative.dfy"
include "td_cache.dfy"
include "hashing.dfy"
include "timelock.dfy"

import opened Interface
import opened Serialization_imperative
import opened ConcreteTimelock
import opened ByteLevelTimelock

class GatekeeperTimelockDrive {
  var cache_size: BoundedInts.uint32
  var log_head: Shared.physical_block_address
  var log_tail: Shared.physical_block_address
  var recovering_mode: bool

  constructor(port: BoundedInts.uint32, init_disk: bool, zero_first_block: bool, cache_size_: BoundedInts.uint32)
  {
    DiskOps.Sync();
    if (zero_first_block) {
      DiskOps.zero_out_blocks();
    }
    expect Constants.MAX_TD_CACHE_SIZE == cache_size_;
    cache_size := cache_size_;
    recovering_mode := !init_disk;

    new; // why is this a thing in Dafny? Seriously this makes no sense
    this.log_head, this.log_tail := load_log_state(init_disk);
  
    var interface_res: Wrappers.Result<(), string> := interface_init(port);
    expect interface_res.Success?, "Failed to initialize interface " + interface_res.error + "\n";
  }

  method persist_log_state(state_block: BoundedInts.bytes)
    requires state_block.Length == Constants.BLOCK_SIZE as nat
    modifies state_block
  {
    Serialization_imperative.uint32_to_bytes(log_head as BoundedInts.uint32, state_block, 0);
    Serialization_imperative.uint32_to_bytes(log_tail as BoundedInts.uint32, state_block, Constants.sizeof_unsigned_int);

    DiskOps.write_blocks(Constants.LOG_STATE_BLOCK, 1, state_block, 0);
    DiskOps.Sync();
  }

  method load_log_state(init_disk: bool) returns (lh: Shared.physical_block_address, lt: Shared.physical_block_address)
  {
    if (init_disk) { return (Constants.TOTAL_NUM_MD_PER_LOG - 2) as Shared.physical_block_address, (Constants.TOTAL_NUM_MD_PER_LOG - 2) as Shared.physical_block_address;}
    var state_block := new BoundedInts.byte[Constants.BLOCK_SIZE](i => 0);
    DiskOps.read_blocks(Constants.LOG_STATE_BLOCK, 1, state_block);

    var persisted_head := Serialization_imperative.bytes_to_uint32(state_block, 0);
    var persisted_tail := Serialization_imperative.bytes_to_uint32(state_block, Constants.sizeof_unsigned_int);

    // Only accept persisted state when it is structurally valid for metadata log blocks.
    expect ((Constants.TOTAL_NUM_MD_PER_LOG - 2) <= persisted_head < Constants.TOTAL_DISK_BLOCKS && (Constants.TOTAL_NUM_MD_PER_LOG - 2) <= persisted_tail < Constants.TOTAL_DISK_BLOCKS);
    return  persisted_head as Shared.physical_block_address, persisted_tail as Shared.physical_block_address;
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

    var curr_time_array : BoundedInts.bytes := new BoundedInts.byte[Constants.sizeof_unsigned_int];
    var evict_obj := new BoundedInts.byte[Constants.EVICT_OBJ_SIZE](i => 0);
    var bytes := new BoundedInts.byte[Constants.BUFFER_SIZE];
    var success_resp := new BoundedInts.byte[1](i => 0);
    var write_denied_resp := new BoundedInts.byte[1](i => 255);
    var freshness_reject_resp := new BoundedInts.byte[1](i => 254);
    var counters: array<BoundedInts.uint32> := new BoundedInts.uint32[Constants.TOTAL_NUM_METADATA_BLOCKS](i => 0);
    var cache: TD_Cache := new TD_Cache(Constants.MAX_TD_CACHE_SIZE);
    var evict_idx: Shared.td_cache_idx_int := 0;
    assert fresh(cache);
    assert fresh(cache.tags);

    while true
      decreases *
      modifies this, bytes, counters, evict_obj, curr_time_array, data_ranges[..], cache.tags
      modifies set i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i]
      invariant fresh(data_ranges)
      invariant fresh(cache)
      invariant fresh(cache.tags)
      invariant fresh(cache.cache_array)
      invariant forall k | 0 <= k < cache.cache_array.Length :: fresh(cache.cache_array[k])
      invariant fresh(bytes)
      invariant fresh(counters)
      invariant fresh(evict_obj)
      invariant cache.cache_requirements()
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

      var timestamp_res: Wrappers.Result<BoundedInts.uint32, string> := Timestamps.ReadTimestamp();
      expect timestamp_res.Success?, "Failed to read timestamp " + timestamp_res.error + "\n";
      var timestamp: BoundedInts.uint32 := timestamp_res.value;

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
        expect write_payload_size == (Constants.sizeof_hash_block_obj * header.num_md_blocks as BoundedInts.uint32) + (tot_blocks * Constants.BLOCK_SIZE);
        var next_evict_idx, cache_update_ok, skip_counter := update_td_metadata_cache(header.num_md_blocks, bytes, evict_obj, cache, counters, evict_idx);
        evict_idx := next_evict_idx;
        evict_obj[0] := header.num_md_blocks - skip_counter;
        if (!cache_update_ok) {
          send_response(freshness_reject_resp, 1);
          continue;
        }
        var write_ok := handle_write(num_data_ranges, header.num_md_blocks as BoundedInts.uint32, data_ranges, timestamp, bytes, cache, counters, curr_time_array);
        if (write_ok) {
          send_response(evict_obj, 1 + ((Constants.sizeof_hash_block_obj) * (header.num_md_blocks - skip_counter) as BoundedInts.uint32));
        } else {
          send_response(write_denied_resp, 1);
        }
      case Sync =>
        DiskOps.Sync();
        // Evict all valid cache blocks back to driver
        // Send all cache blocks (driver filters invalid entries)
        evict_obj[0] := Constants.MAX_TD_CACHE_SIZE as BoundedInts.uint8;
        var resp_idx: BoundedInts.uint32 := 1;
        // var cache_idx: BoundedInts.uint32 := 0;
        for cache_idx: BoundedInts.uint32 := 0 to Constants.MAX_TD_CACHE_SIZE
          invariant cache_idx <= Constants.MAX_TD_CACHE_SIZE
          invariant resp_idx == 1 + (cache_idx * Constants.sizeof_hash_block_obj)
          invariant resp_idx as nat <= evict_obj.Length
          invariant cache.cache_requirements()
        {
          Shared.copy_array(evict_obj, resp_idx, cache.cache_array[cache_idx], 0);
          resp_idx := resp_idx + Constants.sizeof_hash_block_obj;
        }
        send_response(evict_obj, 1 + ((Constants.sizeof_hash_block_obj) * Constants.MAX_TD_CACHE_SIZE));
      case InitCounters =>
        evict_idx := handle_init(cache, counters, bytes, evict_obj);
      case Identify =>
        var state_resp := new BoundedInts.byte[Constants.sizeof_unsigned_int * 2](i => 0);
        Serialization_imperative.uint32_to_bytes(log_head as BoundedInts.uint32, state_resp, 0);
        Serialization_imperative.uint32_to_bytes(log_tail as BoundedInts.uint32, state_resp, Constants.sizeof_unsigned_int);
        send_response(state_resp, Constants.sizeof_unsigned_int * 2);
      case Finish =>
        var state_block := new BoundedInts.byte[Constants.BLOCK_SIZE](i => 0);
        persist_log_state(state_block);
        send_response(success_resp, 1);
        break;
      case _ =>
        expect false, "Invalid disk command issued\n";

      assert fresh(cache.tags);
      assert fresh(cache.cache_array);
      assert forall k | 0 <= k < cache.cache_array.Length :: fresh(cache.cache_array[k]);
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

  method handle_write(num_data_ranges: BoundedInts.uint32, num_md_blocks: BoundedInts.uint32, data_ranges: array<Shared.DataRange>, timestamp: BoundedInts.uint32, bytes: BoundedInts.bytes, cache: TD_Cache, counters: array<BoundedInts.uint32>, curr_time_array: BoundedInts.bytes) returns (write_ok: bool)
    requires num_md_blocks <= Constants.MAX_MD_BLOCKS_IN_HEADER
    requires counters.Length == Constants.TOTAL_NUM_METADATA_BLOCKS as nat
    requires cache.cache_requirements()
    requires curr_time_array.Length == Constants.sizeof_unsigned_int as nat
    requires data_ranges.Length == Constants.MAX_MAPPING_COUNT as nat
    requires 0 < num_data_ranges <= Constants.MAX_MAPPING_COUNT
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    ensures cache.cache_ensures()
    ensures cache.tags == old(cache.tags)
    ensures cache.cache_array == old(cache.cache_array)
    ensures data_ranges[..] == old(data_ranges[..])
    
    modifies this, curr_time_array, counters
    modifies set i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i]
    modifies bytes
  {
    Serialization_imperative.uint32_to_bytes(timestamp, curr_time_array, 0);
    var bytes_offset: BoundedInts.uint32 := (num_md_blocks * Constants.sizeof_hash_block_obj);
    for i: BoundedInts.uint32 := 0 to num_data_ranges
      invariant cache.cache_ensures()
      invariant cache.cache_array[..] == old(cache.cache_array[..])
      invariant bytes_offset <= Constants.BUFFER_SIZE
      invariant bytes_offset % Constants.sizeof_unsigned_int == 0
    {
      var data_range := data_ranges[i];
      expect (data_range.pba as BoundedInts.uint32 + data_range.num_blocks as BoundedInts.uint32 <= Constants.TOTAL_DISK_BLOCKS && bytes_offset <= (Constants.BUFFER_SIZE - Constants.BLOCK_SIZE));
      expect bytes_offset <= Constants.BUFFER_SIZE - (data_range.num_blocks as BoundedInts.uint32 * Constants.BLOCK_SIZE);
      var all_free := ensure_blocks_free(data_range, timestamp, bytes, bytes_offset, cache, counters, curr_time_array);
      if !all_free {return false;}
      DiskOps.write_blocks(data_range.pba as BoundedInts.uint32, data_range.num_blocks as BoundedInts.uint32, bytes, bytes_offset);
      bytes_offset := bytes_offset + (data_range.num_blocks as BoundedInts.uint32 * Constants.BLOCK_SIZE);
      expect bytes_offset <= Constants.BUFFER_SIZE;
    }
    return true;
  }

  method handle_init(cache: TD_Cache, counters: array<BoundedInts.uint32>, bytes: BoundedInts.bytes, evict_obj: BoundedInts.bytes) returns (rei: Shared.td_cache_idx_int)
    requires cache.cache_requirements()
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    requires counters.Length == Constants.TOTAL_NUM_METADATA_BLOCKS as nat
    requires evict_obj.Length == Constants.EVICT_OBJ_SIZE as nat
    ensures cache.cache_ensures()
    ensures cache.tags == old(cache.tags)
    ensures cache.cache_array == old(cache.cache_array)
    ensures cache.cache_array[..] == old(cache.cache_array[..])
    modifies this, bytes, cache.tags, evict_obj, counters
    modifies set i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i]
  {
    var MD_INIT_STATE: seq<BoundedInts.byte> := [0, 0, 0, 0, 1, 0, 0, 0];
    var log_block := new BoundedInts.byte[Constants.BUFFER_SIZE](i => 0);
    var req_buf := new BoundedInts.byte[Constants.sizeof_unsigned_int + (Constants.MAX_TD_CACHE_SIZE * Constants.sizeof_unsigned_int)](i => 0);
    var recovery_curr_time_array := new BoundedInts.byte[Constants.sizeof_unsigned_int](i => 0);
    var replay_evict_idx: Shared.td_cache_idx_int := 0;

    // Compute initial state for every metadata block
    for md_i: BoundedInts.uint32 := 0 to Constants.TOTAL_NUM_METADATA_BLOCKS
      invariant cache.cache_ensures()
    {
      var block := new BoundedInts.byte[Constants.sizeof_hash_block_obj](i => if i < Constants.BLOCK_SIZE as nat then MD_INIT_STATE[i % |MD_INIT_STATE|] else 0);
      assert block != bytes;
      assert block.Length == Constants.sizeof_hash_block_obj as nat;
      // HashBlock writes md index, freshness counter and BLAKE3 hash directly into block.
      var init_hash_res := Hashing.HashBlock(block, md_i as Shared.metadata_block_int, counters[md_i]);
      expect init_hash_res.Success?;
      // Send the freshly hashed block to the driver.
      send_response(block, Constants.sizeof_hash_block_obj);
    }

    // Recovery replay using a cache request protocol.
    if (recovering_mode) {
      var recovered_tail: Shared.physical_block_address := log_tail;
      var curr_replay: Shared.physical_block_address := log_head;
      var visited_replay := new bool[Constants.TOTAL_DISK_BLOCKS](i => false);

      for replay_steps: BoundedInts.uint32 := 0 to Constants.TOTAL_DISK_BLOCKS
        invariant curr_replay as BoundedInts.uint32 < Constants.TOTAL_DISK_BLOCKS
      {
        if (curr_replay == recovered_tail || visited_replay[curr_replay as BoundedInts.uint32]) { break; }
        visited_replay[curr_replay as BoundedInts.uint32] := true;

        DiskOps.read_blocks(curr_replay as BoundedInts.uint32, 1, log_block);

        // Collect distinct md indices needed by this replay log block.
        var needed_mds := new Shared.metadata_block_int[Constants.MAX_TD_CACHE_SIZE](k => (Constants.TOTAL_NUM_METADATA_BLOCKS - 1) as Shared.metadata_block_int);
        var n_needed: BoundedInts.uint8 := 0;
        for ri := 0 to Constants.TOTAL_NUM_MD_PER_LOG
          invariant ri <= Constants.TOTAL_NUM_MD_PER_LOG
          invariant n_needed as BoundedInts.uint32 <= Constants.MAX_TD_CACHE_SIZE
        {
          var pba := Serialization_imperative.bytes_to_uint32(log_block, ri * Constants.sizeof_unsigned_int);
          if (pba >= Constants.TOTAL_DISK_BLOCKS) { continue; }

          var (rmd, _) := Shared.pba_to_md_and_offset(pba as Shared.physical_block_address);
          var already := false;
          for q: BoundedInts.uint8 := 0 to n_needed //&& !already
            invariant q <= n_needed
          {
            if (needed_mds[q] == rmd) { already := true; break; }
          }
          if (!already) {
            expect n_needed as BoundedInts.uint32 < Constants.MAX_TD_CACHE_SIZE, "recovery log entry requires more cache blocks than MAX_TD_CACHE_SIZE";
            needed_mds[n_needed] := rmd;
            n_needed := n_needed + 1;
          }
        }

        // Request needed metadata indices from driver for this replay step.
        Serialization_imperative.uint32_to_bytes(n_needed as BoundedInts.uint32, req_buf, 0);
        for rq_i := 0 to n_needed
          invariant rq_i <= n_needed
        {
          Serialization_imperative.uint32_to_bytes(needed_mds[rq_i] as BoundedInts.uint32, req_buf, Constants.sizeof_unsigned_int + (rq_i as BoundedInts.uint32 * Constants.sizeof_unsigned_int));
        }
        send_response(req_buf, Constants.sizeof_unsigned_int + (n_needed as BoundedInts.uint32 * Constants.sizeof_unsigned_int));

        // Receive requested metadata blocks and populate cache.
        var recv_res := interface_receive(bytes, n_needed as BoundedInts.uint32 * Constants.sizeof_hash_block_obj);
        expect recv_res.Success?, "Failed to receive recovery cache blocks from driver\n";
        var next_idx, recovery_cache_ok, _ := update_td_metadata_cache(n_needed, bytes, evict_obj, cache, counters, replay_evict_idx);
        expect recovery_cache_ok, "Recovery cache prepopulate failed\n";
        replay_evict_idx := next_idx;

        // Apply log update over cache-backed metadata.
        ComputeLogUpdates(log_block, 0, cache, counters, recovery_curr_time_array);

        Serialization_imperative.uint32_to_bytes(n_needed as BoundedInts.uint32, req_buf, 0);
        send_response(req_buf, Constants.sizeof_unsigned_int);
        
        for rq_i := 0 to n_needed
          invariant rq_i <= n_needed
        {
          var cache_pos: Shared.td_cache_idx_int := cache.scan_cache(needed_mds[rq_i]);
          send_response(cache.cache_array[cache_pos], Constants.sizeof_hash_block_obj);
        }

        var pointer_next_replay := Serialization_imperative.bytes_to_uint32(log_block, ((Constants.TOTAL_NUM_MD_PER_LOG + 2) * Constants.sizeof_unsigned_int));
        if (pointer_next_replay >= Constants.TOTAL_DISK_BLOCKS) { break; }
        curr_replay := pointer_next_replay as Shared.physical_block_address;
      }

      log_tail := recovered_tail;
    }

    // Termination sentinel: uint32 0xFFFFFFFF signals end of Phase 2 stream.
    // The driver reads this in both recovery and non-recovery modes.
    var sentinel_buf := new BoundedInts.byte[4](k => 255);
    send_response(sentinel_buf, 4);

    return replay_evict_idx;
  }

  method update_td_metadata_cache(num_md_blocks: BoundedInts.uint8, bytes: BoundedInts.bytes, evict_obj: BoundedInts.bytes, cache: TD_Cache, counters: array<BoundedInts.uint32>, e_idx: Shared.td_cache_idx_int) returns (idx: Shared.td_cache_idx_int, update_ok: bool, skipped: BoundedInts.uint8)
    requires counters.Length == Constants.TOTAL_NUM_METADATA_BLOCKS as nat
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    requires evict_obj.Length == Constants.EVICT_OBJ_SIZE as nat
    requires cache.cache_requirements()
    requires 0 <= num_md_blocks as BoundedInts.uint32 <= Constants.MAX_MD_BLOCKS_IN_HEADER
    ensures cache.cache_ensures()
    ensures cache.tags == old(cache.tags)
    ensures cache.cache_array == old(cache.cache_array)
    ensures cache.cache_array[..] == old(cache.cache_array[..])
    ensures skipped <= num_md_blocks
    modifies this, evict_obj
    modifies counters
    modifies cache.tags
    modifies set i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i]
  {
    var evict_idx: Shared.td_cache_idx_int := e_idx;
    var skip_counter: BoundedInts.uint8 := 0;

    for i := 0 to num_md_blocks
      invariant cache.cache_ensures()
      invariant i as int <= num_md_blocks as int
      invariant skip_counter <= i <= num_md_blocks
    {
      var md_idx: BoundedInts.uint32 := Serialization_imperative.bytes_to_uint32(bytes, (Constants.sizeof_hash_block_obj * i as BoundedInts.uint32) + Constants.BLOCK_SIZE);
      var counter: BoundedInts.uint32 := Serialization_imperative.bytes_to_uint32(bytes, (Constants.sizeof_hash_block_obj * i as BoundedInts.uint32) + Constants.BLOCK_SIZE + Constants.sizeof_unsigned_int);

      if md_idx >= Constants.TOTAL_NUM_METADATA_BLOCKS { return e_idx, false, 0; }
      var already_cached, _ := Shared.find_needle_in_haystack(cache.tags, cache.tags.Length as BoundedInts.uint32, md_idx as Shared.metadata_block_int);
      // var already_cached, _ := cache.contains_tag(md_idx as Shared.metadata_block_int);
      if (already_cached) {
        skip_counter := skip_counter + 1;
        continue;
      }

      var hash_eq_res: Wrappers.Result<bool, string> := Hashing.CheckHash(bytes, Constants.sizeof_hash_block_obj * i as BoundedInts.uint32);
      if (!hash_eq_res.Success? || !hash_eq_res.value || counter != counters[md_idx]) {
        return e_idx, false, 0;
      }

      Shared.copy_array(evict_obj, 1 + (Constants.sizeof_hash_block_obj * (i - skip_counter) as BoundedInts.uint32), cache.cache_array[evict_idx], 0);
      cache.cache_insert(md_idx as Shared.metadata_block_int, bytes, Constants.sizeof_hash_block_obj * i as BoundedInts.uint32, evict_idx);
      evict_idx := (((evict_idx as BoundedInts.uint32) + 1) % Constants.MAX_TD_CACHE_SIZE) as Shared.td_cache_idx_int;
    }

    return evict_idx, true, skip_counter;
  }

  method ensure_blocks_free(data_range: Shared.DataRange, timestamp: BoundedInts.uint32, bytes: BoundedInts.bytes, bytes_offset: BoundedInts.uint32, cache: TD_Cache, counters: array<BoundedInts.uint32>, curr_time_array: BoundedInts.bytes) returns (all_free: bool)
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    requires bytes_offset <= Constants.BUFFER_SIZE - (data_range.num_blocks as BoundedInts.uint32 * Constants.BLOCK_SIZE)
    requires bytes_offset % Constants.sizeof_unsigned_int == 0
    requires curr_time_array.Length == Constants.sizeof_unsigned_int as nat
    requires counters.Length == Constants.TOTAL_NUM_METADATA_BLOCKS as nat
    requires data_range.pba as BoundedInts.uint32 + data_range.num_blocks as BoundedInts.uint32 <= Constants.TOTAL_DISK_BLOCKS
    requires cache.cache_requirements()
    ensures cache.cache_ensures()
    modifies this, curr_time_array, counters
    modifies set i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i]
  {
    var prev_md: BoundedInts.uint32 := BoundedInts.UINT32_MAX;
    Serialization_imperative.uint32_to_bytes(timestamp, curr_time_array, 0);
    for i := 0 to data_range.num_blocks as BoundedInts.uint32
      invariant cache.cache_ensures()
      invariant i <= data_range.num_blocks as BoundedInts.uint32
    {
      var pba := (data_range.pba as BoundedInts.uint32 + i) as Shared.physical_block_address;
      var (md, offset) := Shared.pba_to_md_and_offset(pba);
      if (prev_md != md as BoundedInts.uint32) {
        var cache_idx := cache.scan_cache(md);
        var md_offset := offset as BoundedInts.uint32 * Constants.sizeof_MetadataEntry;
        if !ByteLevelTimelock.IsFreeBytes(cache.cache_array[cache_idx], md_offset, curr_time_array, 0) {return false;}
        prev_md := md as BoundedInts.uint32;
      }
      if pba == log_tail { // block is timelock metadata condition
        var offset_within_block := ((Constants.TOTAL_NUM_MD_PER_LOG + 2) * Constants.sizeof_unsigned_int);
        var offset_within_bytes := bytes_offset + (i * Constants.BLOCK_SIZE);
        var pointer_next := Serialization_imperative.bytes_to_uint32(bytes, offset_within_bytes + offset_within_block);
        expect pointer_next < Constants.TOTAL_DISK_BLOCKS;
        log_tail := pointer_next as Shared.physical_block_address;
        ComputeLogUpdates(bytes, offset_within_bytes, cache, counters, curr_time_array);
      }
    }

    return true;
  }

  method ComputeLogUpdates(log: BoundedInts.bytes, log_offset: BoundedInts.uint32, cache: TD_Cache, counters: array<BoundedInts.uint32>, curr_time_array: BoundedInts.bytes)
    requires counters.Length == Constants.TOTAL_NUM_METADATA_BLOCKS as nat
    requires forall i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i] != log
    requires log.Length == Constants.BUFFER_SIZE as nat
    requires log_offset as nat <= log.Length
    requires (log_offset as nat + log.Length) < BoundedInts.TWO_TO_THE_32
    requires (log_offset + Constants.BLOCK_SIZE) as nat <= log.Length
    requires (log_offset % Constants.sizeof_unsigned_int) == 0
    requires curr_time_array.Length == Constants.sizeof_unsigned_int as nat
    requires cache.cache_requirements()
    ensures cache.cache_ensures()
    modifies this, counters
    modifies set i | 0 <= i < cache.cache_array.Length :: cache.cache_array[i]
  {
    var keep_duration_log_offset: BoundedInts.uint32 := log_offset + (Constants.TOTAL_NUM_MD_PER_LOG * Constants.sizeof_unsigned_int);
    var current_time_log_offset: BoundedInts.uint32 := log_offset + ((Constants.TOTAL_NUM_MD_PER_LOG + 1) * Constants.sizeof_unsigned_int);
    var prev_md: BoundedInts.uint32 := BoundedInts.UINT32_MAX;
    var prev_idx: Shared.td_cache_idx_int := 0;
    var touched_slots := new Shared.td_cache_idx_int[Constants.MAX_TD_CACHE_SIZE * 2](k => 0);
    var touched_count: BoundedInts.uint32 := 0;

    for i: BoundedInts.uint32 := 0 to Constants.TOTAL_NUM_MD_PER_LOG
      invariant cache.cache_ensures()
      invariant cache.cache_array[..] == old(cache.cache_array[..])
      invariant forall c_idx | 0 <= c_idx < cache.cache_array.Length :: cache.cache_array[c_idx] != log
      invariant touched_count as nat <= touched_slots.Length
    {
      var pba := Serialization_imperative.bytes_to_uint32(log, log_offset + (i * 4));
      if (pba >= Constants.TOTAL_DISK_BLOCKS) {
        continue;
      }
      var (md, offset) := Shared.pba_to_md_and_offset(pba as Shared.physical_block_address);
      var idx: Shared.td_cache_idx_int;
      if (prev_md == md as BoundedInts.uint32) {
        idx := prev_idx;
      } else {
        idx := cache.scan_cache(md);
        prev_md := md as BoundedInts.uint32;
        prev_idx := idx;

        expect touched_count < Constants.MAX_TD_CACHE_SIZE * 2;
        touched_slots[touched_count] := idx;
        touched_count := touched_count + 1;
      }

      var md_offset: BoundedInts.uint32 := offset as BoundedInts.uint32 * 8;

      expect !WouldOverflowBytes(cache.cache_array[idx], md_offset, log, current_time_log_offset), "time overflows!";
      ByteLevelTimelockNext(cache.cache_array[idx], md_offset, log, keep_duration_log_offset, log, current_time_log_offset);
    }

    for refresh_i := 0 to touched_count
      invariant refresh_i <= touched_count
      invariant touched_count as nat <= touched_slots.Length
      invariant cache.cache_ensures()
    {
      var cache_pos := touched_slots[refresh_i];
      var already_updated, _ := Shared.find_needle_in_haystack(touched_slots, refresh_i, cache_pos);
      if already_updated { continue; }
      
      var md_to_refresh := cache.tags[cache_pos];
      // expect md_to_refresh < Constants.TOTAL_NUM_METADATA_BLOCKS, "ComputeLogUpdates touched invalid md index\n";
      expect counters[md_to_refresh] < (BoundedInts.UINT32_MAX), "Metadata freshness counter overflow in ComputeLogUpdates\n";
      counters[md_to_refresh] := counters[md_to_refresh] + 1;

      var rehash_res := Hashing.HashBlock(cache.cache_array[cache_pos], cache.tags[cache_pos], counters[md_to_refresh]);
      expect rehash_res.Success?, "Failed to refresh hash after ComputeLogUpdates\n";
    }
  }
}
