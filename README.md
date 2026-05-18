# Timelock Drive

An implementation of the timelock storage system. The **gatekeeper** (Dafny →
Rust) enforces the timelock policies on the disk; the **versioning driver**
(C / bdus) exposes a versioned virtual block device and manages versions in a timelock-respecting manner.
This artifact accompanies the paper "Timelock Drive: Isolated Time-Based Defense for Storage Systems," OSDI 2026.

## Build Dependencies
This artifact uses the BDUS framework. The authors have tested that the framework works with Ubuntu 20.04 and note that it may not build on newer distros (22.04 and 24.04).

## WARNING
This prototype interacts with storage devices. Unless you know what you are doing/contact the authors
it is highly recommended that you run the system in the default mode using the DRAM backed disk (instructions below). If you use a persistent medium (HDD/SSD) the gatekeeper will pass through
raw physical block addresses which will overwrite whatever you have stored. Only point this prototype 
at a physical device that you do not have any important information stored on.

## Quick start — one command

```bash
sudo -E ./setup.sh --ramdisk
```

This single script installs every dependency, builds both components, and
creates a 10 GiB RAM disk ready for testing. Add `--skip-verify` to skip full
Dafny verification (adds ~10–30 min). Drop `--ramdisk` to use a
physical disk configured in `/etc/timelockdrive/gatekeeper.toml`.

Full option reference:

```
sudo -E ./setup.sh [--ramdisk | --ramdisk-dev-mode] [--skip-verify] [--help]

  --ramdisk          Set up a 10 GiB RAM disk at /dev/ram0 after building.
  --ramdisk-dev-mode Set up a 1 GiB RAM disk instead (quick testing).
  --skip-verify      Skip Dafny verification; just compile and link.
```

> **Note:** `sudo -E` is required so that Rust/Cargo installs into your home
> directory rather than `/root`.

---

## Step-by-step (if you need to repeat one)

### 1. Install dependencies

```bash
# Driver (C / bdus kernel module)
sudo ./install_deps_driver.sh

# Gatekeeper (.NET 8, Dafny 4.10, Rust stable)
sudo -E ./install_deps_gatekeeper.sh
```

### 2. Build

```bash
# Driver + shared library
make -C versioning_td_driver

# Gatekeeper — verify and build (slow, ~10–30 min)
make -C gatekeeper all

# Gatekeeper — build only, skip verification
make -C gatekeeper build
```

### 3. Configure the disk

Edit `/etc/timelockdrive/gatekeeper.toml` (created by `setup.sh`, or copy
from `gatekeeper/gatekeeper.toml`):

```toml
disk_path = "/dev/ram0"   # or "/dev/sdb" for a physical disk
```

Alternatively, set the `GK_DISK_PATH` environment variable at runtime:

```bash
export GK_DISK_PATH=/dev/ram0
```

### 4. Set up a RAM disk (optional, for testing)

```bash
sudo ./setup_ramdisk.sh               # 10 GiB RAM disk at /dev/ram0
sudo ./setup_ramdisk.sh --dev-mode    # 1 GiB  (for memory-constrained machines)
sudo ./setup_ramdisk.sh --teardown    # destroy RAM disks and restore config
```

The script writes `/tmp/td_ramdisk.env` which you can `source` to set
`GK_DISK_PATH` automatically.

---

## Running the stack

Open two terminals from the repository root.

**Terminal 1 — gatekeeper**

```bash
source /tmp/td_ramdisk.env          # set GK_DISK_PATH (if using a RAM disk)
sudo -E ./gatekeeper/gatekeeper/main-rust/target/release/main --timelockdrive
```

Add `--ipc` to use the IPC transport instead of the default network transport.

**Terminal 2 — driver**

```bash
sudo ./versioning_td_driver/bin/versioning_td_driver
```

---

## Running the tests

All tests require the gatekeeper and driver to **not** be running (the test
scripts start their own instances).

### End-to-end test suite

```bash
cd versioning_td_driver

# Run all e2e tests
make e2e_suite

```

Individual tests can be run by target name, e.g.:

```bash
make e2e_flush          # gatekeeper flush durability
make e2e_recovery       # gatekeeper recovery after crash
make e2e_sync           # sync / fsync durability
make e2e_timelock_state # timelock state machine
make e2e_freshness      # freshness counter
make e2e_fs_mount_recovery # mounts a filesystem on the block device, tests that it can recover the state across crashes.
make e2e_fs_timelock_recovery # as as above but also checks the "recover before intrustion time" capabilities of driver
make e2e_gatekeeper_log_state # confirms that the gatekeeper log head/tail are correctly persisted.
make e2e_driver_restart_recovery # tests basic recovery logic of the driver
make e2e_sequential_writes # confirms sequential write pattern of driver/gatekeeper during normal operations
```

Each test has a 4-minute timeout. Logs are written to a temporary directory
printed at the end of the run.

### Unit tests

```bash
cd versioning_td_driver
make unit_gc_test_run
make unit_cache_membership_test_run
make unit_recovery_state_test_run
```

---

## Repository layout

```
setup.sh                    one-shot install + build script
install_deps_driver.sh      driver dependency installer
install_deps_gatekeeper.sh  gatekeeper dependency installer
setup_ramdisk.sh            RAM disk setup / teardown

gatekeeper/                 formally-verified gatekeeper (Dafny → Rust)
  gatekeeper/               Dafny source files
  rust-externs/             Rust extern implementations (externs.rs)
  gatekeeper.toml           default disk config template

versioning_td_driver/       versioning block-device driver (C / bdus)
  src/                      driver source
  tests/                    e2e and unit test scripts
  bin/                      compiled driver binary (after build)

shared/                     shared C library (used by driver)
bdus/                       git submodule — bdus kernel framework
```
