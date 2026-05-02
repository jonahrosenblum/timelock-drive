#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <gatekeeper-main-rs>" >&2
    exit 2
fi

main_rs="$1"
if [[ ! -f "$main_rs" ]]; then
    echo "missing file: $main_rs" >&2
    exit 2
fi

# Already patched: nothing to do.
if rg -q '^\s*\[gk_trace\] recv_write|trace_writes' "$main_rs"; then
    exit 0
fi

tmp_file="${main_rs}.tmp.$$"

if ! awk '
BEGIN {
    inserted_trace_flag = 0;
    inserted_recv_write = 0;
    inserted_recv_range = 0;
}
{
    print $0;

    if ($0 ~ /let mut write_ok: bool = <bool as Default>::default\(\);/) {
        print "            let trace_writes = std::env::var(\"GK_TRACE_WRITES\").map(|v| v != \"0\").unwrap_or(false);";
        inserted_trace_flag = 1;
    }

    if ($0 ~ /let mut bytes_offset: u32 = num_md_blocks \* crate::Constants::_default::sizeof_hash_block_obj\(\);/) {
        print "            if trace_writes {";
        print "                eprintln!(";
        print "                    \"[gk_trace] recv_write num_data_ranges={} num_md_blocks={} timestamp={}\",";
        print "                    num_data_ranges,";
        print "                    num_md_blocks,";
        print "                    timestamp";
        print "                );";
        print "            }";
        inserted_recv_write = 1;
    }

    if (inserted_recv_write && $0 ~ /let mut data_range: Object<DataRange> = rd!\(data_ranges\)\[DafnyUsize::into_usize\(i\)\]\.clone\(\);/) {
        print "                if trace_writes {";
        print "                    eprintln!(";
        print "                        \"[gk_trace] recv_range[{}] pba={} blocks={} bytes_offset={}\",";
        print "                        i,";
        print "                        read_field!(rd!(data_range.clone()).pba),";
        print "                        read_field!(rd!(data_range.clone()).num_blocks),";
        print "                        bytes_offset";
        print "                    );";
        print "                }";
        inserted_recv_range = 1;
    }
}
END {
    if (!(inserted_trace_flag && inserted_recv_write && inserted_recv_range)) {
        exit 3;
    }
}
' "$main_rs" >"$tmp_file"; then
    rm -f "$tmp_file"
    echo "failed to patch $main_rs; generated layout changed" >&2
    exit 1
fi

mv "$tmp_file" "$main_rs"
echo "applied gatekeeper trace patch to $main_rs"