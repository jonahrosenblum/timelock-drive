include "timelock.dfy"
include "shared.dfy"

module ProofObligations {
  import opened Shared
  import opened ConcreteTimelock
  import opened BoundedInts

  type MetadataState = seq<TimelockMetadataEncoding>

  datatype Transaction = Transaction(
    pbas: seq<physical_block_address>,
    keep_duration: uint32,
    current_time: uint32
  )

  type TransactionLog = seq<Transaction>

  function ExecuteTransaction(state: MetadataState, tx: Transaction): MetadataState
  {
    ExecuteTransactionSeq(state, tx.pbas, tx.keep_duration, tx.current_time)
  }

  function {:opaque} ExecuteTransactionSeq(state: MetadataState, pbas: seq<physical_block_address>, keep_duration: uint32, current_time: uint32): MetadataState
    decreases |pbas|
  {
    if |pbas| == 0 then state
    else
      var pba := pbas[0];
      // If the address exists and deadline is valid, apply ConcreteTimelockNext
      var next_state := if pba as nat < |state| && ValidDeadline(state[pba as nat], current_time)
        then state[pba as nat := ConcreteTimelockNext(state[pba as nat], keep_duration, current_time)]
        else state; // Fallback for invalid states or unmapped memory to keep the function total
      ExecuteTransactionSeq(next_state, pbas[1..], keep_duration, current_time)
  }

  lemma LemmaExecuteTransactionSeqAppend(state: MetadataState, pbas: seq<physical_block_address>, pba: physical_block_address, keep_duration: uint32, current_time: uint32)
    ensures 
      var mid_state := ExecuteTransactionSeq(state, pbas, keep_duration, current_time);
      var end_state := if pba as nat < |mid_state| && ValidDeadline(mid_state[pba as nat], current_time) 
                       then mid_state[pba as nat := ConcreteTimelockNext(mid_state[pba as nat], keep_duration, current_time)] 
                       else mid_state;
      ExecuteTransactionSeq(state, pbas + [pba], keep_duration, current_time) == end_state
    decreases |pbas|
  {
    reveal ExecuteTransactionSeq();
    if |pbas| == 0 {
      assert pbas + [pba] == [pba];
    } else {
      var head := pbas[0];
      var tail := pbas[1..];
      var next_state := if head as nat < |state| && ValidDeadline(state[head as nat], current_time) 
                        then state[head as nat := ConcreteTimelockNext(state[head as nat], keep_duration, current_time)] 
                        else state;
      assert pbas + [pba] == [head] + (tail + [pba]);
      LemmaExecuteTransactionSeqAppend(next_state, tail, pba, keep_duration, current_time);
    }
  }

  function ReplayTransaction(state: MetadataState, tx: Transaction): MetadataState {
    ExecuteTransaction(state, tx)
  }

  datatype SystemState = SystemState(metadata: MetadataState, log: TransactionLog)

  function ExecuteStep(state: SystemState, tx: Transaction): SystemState {
    SystemState(ExecuteTransaction(state.metadata, tx), state.log + [tx])
  }

  function ExecuteTrace(state: SystemState, txs: seq<Transaction>): SystemState
    decreases |txs|
  {
    if |txs| == 0 then state else ExecuteTrace(ExecuteStep(state, txs[0]), txs[1..])
  }

  function ReplayLog(state: MetadataState, log: TransactionLog): MetadataState
    decreases |log|
  {
    if |log| == 0 then state else ReplayLog(ReplayTransaction(state, log[0]), log[1..])
  }

  // helper proofs...
  lemma ExecuteTraceAppendsLog(state: SystemState, txs: seq<Transaction>)
    ensures ExecuteTrace(state, txs).log == state.log + txs
    decreases |txs|
  {
    if |txs| != 0 { ExecuteTraceAppendsLog(ExecuteStep(state, txs[0]), txs[1..]); }
  }

  lemma ReplayAppendStep(state: MetadataState, prefix: TransactionLog, tx: Transaction)
    ensures ReplayLog(state, prefix + [tx]) == ReplayTransaction(ReplayLog(state, prefix), tx)
    decreases |prefix|
  {
    if |prefix| != 0 {
      var head := prefix[0];
      var tail := prefix[1..];
      assert prefix == [head] + tail;
      assert prefix + [tx] == [head] + (tail + [tx]);
      ReplayAppendStep(ReplayTransaction(state, head), tail, tx);
    }
  }

  lemma ExecuteStepPreservesReplayInvariant(initial_metadata: MetadataState, state: SystemState, tx: Transaction)
    requires ReplayLog(initial_metadata, state.log) == state.metadata
    ensures ReplayLog(initial_metadata, ExecuteStep(state, tx).log) == ExecuteStep(state, tx).metadata
  {
    ReplayAppendStep(initial_metadata, state.log, tx);
  }

  lemma ExecuteTracePreservesReplayInvariant(initial_metadata: MetadataState, state: SystemState, txs: seq<Transaction>)
    requires ReplayLog(initial_metadata, state.log) == state.metadata
    ensures ReplayLog(initial_metadata, ExecuteTrace(state, txs).log) == ExecuteTrace(state, txs).metadata
    decreases |txs|
  {
    if |txs| != 0 {
      ExecuteStepPreservesReplayInvariant(initial_metadata, state, txs[0]);
      ExecuteTracePreservesReplayInvariant(initial_metadata, ExecuteStep(state, txs[0]), txs[1..]);
    }
  }

  lemma ReplayReconstructsAfterExecution(initial_metadata: MetadataState, txs: seq<Transaction>)
    ensures
      var start := SystemState(initial_metadata, []);
      var end_state := ExecuteTrace(start, txs);
      && end_state.log == txs
      && ReplayLog(initial_metadata, end_state.log) == end_state.metadata
  {
    var start := SystemState(initial_metadata, []);
    ExecuteTraceAppendsLog(start, txs);
    ExecuteTracePreservesReplayInvariant(initial_metadata, start, txs);
  }

  lemma RecoveryEquivalence(initial_metadata: MetadataState, txs: seq<Transaction>)
    ensures ReplayLog(initial_metadata, txs) == ExecuteTrace(SystemState(initial_metadata, []), txs).metadata
  {
    ReplayReconstructsAfterExecution(initial_metadata, txs);
  }

}
