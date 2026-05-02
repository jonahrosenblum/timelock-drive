include "constants.dfy"
include "disk_ops.dfy"

class TD_Cache {
  var cache_array: array<array<BoundedInts.byte>>
  var tags: array<Shared.metadata_block_int>
  // var guess: Shared.td_cache_idx_int
  /*
  FOR INTERNAL USE (member functions)
  */

  predicate cache_requirements()
    reads this
    reads cache_array
    reads cache_array[..]
    reads tags
  {
    && (cache_array.Length == Constants.MAX_TD_CACHE_SIZE as nat)
    && (tags.Length == cache_array.Length)
    && (forall i | 0 <= i < cache_array.Length :: cache_array[i].Length == Constants.sizeof_hash_block_obj as nat)
  }

  twostate predicate cache_ensures()
    reads this
    reads cache_array
    reads cache_array[..]
    reads tags
  {
    && cache_requirements()
    && old(this.cache_requirements())
    && cache_array == old(cache_array)
    && cache_array[..] == old(cache_array[..])
    && tags == old(tags)
    && (forall i | 0 <= i < cache_array.Length :: cache_array[i] == old(cache_array[i]))
  }

  constructor(cache_size: BoundedInts.uint32)
    requires cache_size == Constants.MAX_TD_CACHE_SIZE
    ensures cache_requirements()
    ensures forall i | 0 <= i < cache_array.Length :: fresh(cache_array[i])
    ensures forall i | 0 <= i < cache_array.Length :: fresh(cache_array[i])
    ensures fresh(cache_array)
    ensures fresh(cache_array[..])
    ensures fresh(tags)
    ensures fresh(this)
  {
    var default_entry: array<BoundedInts.byte> := new BoundedInts.byte[Constants.sizeof_hash_block_obj](i => (BoundedInts.TWO_TO_THE_8 - 1) as BoundedInts.byte);
    var cache_array_: array<array<BoundedInts.byte>> := new array<BoundedInts.byte>[cache_size](i => default_entry);
    var tags_array_: array<Shared.metadata_block_int> := new Shared.metadata_block_int[cache_size](i => 0);
    for i: BoundedInts.uint32 := 0 to cache_size
      invariant i <= cache_size
      invariant forall j | 0 <= j && j < i :: fresh(cache_array_[j])
      invariant forall j | 0 <= j && j < i :: fresh(cache_array_[j])
      invariant forall j | 0 <= j && j < i :: cache_array_[j].Length == Constants.sizeof_hash_block_obj as nat
    {
      var entry: array<BoundedInts.byte> := new BoundedInts.byte[Constants.sizeof_hash_block_obj](j => (BoundedInts.TWO_TO_THE_8 - 1) as BoundedInts.byte);
      cache_array_[i] := entry;
      tags_array_[i] := (Constants.TOTAL_NUM_METADATA_BLOCKS - 1) as Shared.metadata_block_int;
    }
    assert cache_array_.Length > 0;

    cache_array := cache_array_;
    tags := tags_array_;
  }

  /* 
  USEABLE BY EXTERNAL CODE (public functions)
  */

  method scan_cache(tag: Shared.metadata_block_int) returns (idx: Shared.td_cache_idx_int)
    requires cache_requirements()

    ensures idx as nat < cache_array.Length && idx as nat < tags.Length
    ensures tags[idx] == tag
    ensures cache_array == old(cache_array)
    ensures forall i :: 0 <= i < cache_array.Length ==> this.cache_array[i] == old(this.cache_array[i])
    ensures forall i :: 0 <= i < cache_array.Length ==> this.cache_array[i] == old(this.cache_array[i])
    ensures cache_ensures()
  {
    var found, i := Shared.find_needle_in_haystack(this.tags, this.tags.Length as BoundedInts.uint32, tag);
    expect found, "Cache block should be in cache, but it's not!";
    return i as Shared.td_cache_idx_int;
  }

  // method contains_tag(tag: Shared.metadata_block_int) returns (found: bool, idx: Shared.td_cache_idx_int)
  //   requires cache_requirements()
  //   ensures cache_ensures()
  //   ensures !found ==> idx == 0
  //   ensures found ==> tags[idx] == tag
  //   modifies this
  // {
  //   var f, i := Shared.find_needle_in_haystack(this.tags, this.tags.Length as BoundedInts.uint32, tag);
  //   if (f) {
  //     print "CACHE_HIT md=", tag as BoundedInts.uint32, "\n";
  //   }
  //   return f, i as Shared.td_cache_idx_int;
  // }

  method cache_insert(tag: Shared.metadata_block_int, bytes: BoundedInts.bytes, bytes_offset: BoundedInts.uint32, evict_idx: Shared.td_cache_idx_int)
    requires cache_requirements()
    requires bytes.Length == Constants.BUFFER_SIZE as nat
    requires bytes_offset as nat < bytes.Length
    requires (bytes_offset + Constants.sizeof_hash_block_obj) as nat <= bytes.Length
    ensures cache_ensures()
    ensures tags[evict_idx] == tag
    modifies this.cache_array[evict_idx], this.tags
  {
    Shared.copy_array(cache_array[evict_idx], 0, bytes, bytes_offset);
    tags[evict_idx] := tag;
  }
}