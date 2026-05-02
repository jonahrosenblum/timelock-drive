include "gatekeeper-timelockdrive-neveroverwrite.dfy"
include "baseline.dfy"

// https://stackoverflow.com/questions/62722832/convert-numbers-to-strings
module {:options "/functionSyntax:4"} Printer {
  type stringNat = s: string |
      |s| > 0 && (|s| > 1 ==> s[0] != '0') &&
      forall i | 0 <= i < |s| :: s[i] in "0123456789"
    witness "1"

  predicate isStringNat(s: string) { |s| > 0 && (|s| > 1 ==> s[0] != '0') && forall i | 0 <= i < |s| :: s[i] in "0123456789" }

  function stringToNat(s: stringNat): nat
    decreases |s|
  {
    if |s| == 1 then
      match s[0]
      case '0' => 0 case '1' => 1 case '2' => 2 case '3' => 3 case '4' => 4
      case '5' => 5 case '6' => 6 case '7' => 7 case '8' => 8 case '9' => 9
    else
      stringToNat(s[..|s|-1])*10 + stringToNat(s[|s|-1..|s|])
  }
}

method Main(args: seq<string>)
decreases *
{
  var init: bool := true;
  var baseline: bool := false;
  var zero_first_block: bool := true;
  var cache_size: nat := 1;
  var timelockdrive: bool := false;
  var use_ipc: bool := false;

  var i: nat := 0;
  while i < |args| {
    if (args[i] == "--no-init") { init := false; }
    else if (args[i] == "--timelockdrive") {
      timelockdrive := true;
      cache_size := Constants.MAX_TD_CACHE_SIZE as nat;
    }
    else if (args[i] == "--no-zero") { zero_first_block := false; }
    else if (args[i] == "--baseline") { baseline := true; }
    else if (args[i] == "--cache-size") {
      expect i + 1 < |args|;
      expect Printer.isStringNat(args[i + 1]);
      cache_size := Printer.stringToNat(args[i + 1]);
    }
    else if (args[i] == "--ipc") { use_ipc := true; }
    i := i + 1;
  }

  Interface.interface_set_ipc_mode(use_ipc);

  expect cache_size < BoundedInts.TWO_TO_THE_32, "Cache size cannot fit in a 32 bit int.";

  if (timelockdrive) {
    var gatekeeper: GatekeeperTimelockDrive := new GatekeeperTimelockDrive(Constants.PORT_NUMBER, init, zero_first_block, cache_size as BoundedInts.uint32);
    gatekeeper.parse_requests();
  }

  else if (baseline) {
    var gatekeeper: GatekeeperBaseline := new GatekeeperBaseline(Constants.PORT_NUMBER, init, zero_first_block);
    gatekeeper.parse_requests();
  }
}