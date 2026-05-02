# Based on https://hiltmon.com/blog/2013/07/03/a-simple-c-plus-plus-project-structure/
CC := gcc
SRCDIR := src
BUILDDIR := build
SHAREDBUILDDIR := ../shared/build
TARGETDIR := bin

SRCEXT := c
# List of source files
SOURCES = $(shell find $(SRCDIR) -type f -name *.c)
SOURCES += $(shell find $(SRCDIR) -type f -name *.cpp)
# Generate the names of the object files
OBJECTS := $(patsubst $(SRCDIR)/%,$(BUILDDIR)/%,$(SOURCES:.$(SRCEXT)=.o))
OBJECTS += $(shell find $(SHAREDBUILDDIR) -type f -name *.o)
CFLAGS := -O3 -g
BDUSFLAGS := -lbdus
INC := -I ../shared/include -I include
LIBTHREAD := -pthread
LIBRT := -lrt
MOUNT_DIR := mount-point/

current_bdus=`cat current_bdus.txt`

UNIT_TEST_TARGETS := unit_gc_test_run unit_cache_membership_test_run unit_recovery_state_test_run
E2E_TEST_TARGETS := e2e_flush e2e_recovery e2e_sync e2e_timelock_state e2e_timelock_durations e2e_freshness e2e_fs_mount_recovery e2e_gatekeeper_log_state e2e_driver_restart_recovery e2e_fs_timelock_recovery e2e_sequential_writes

all: shared versioning_td_driver

.PHONY: e2e_flush e2e_recovery e2e_sync e2e_timelock_state e2e_timelock_durations e2e_freshness e2e_fs_mount_recovery e2e_gatekeeper_log_state e2e_driver_restart_recovery e2e_fs_timelock_recovery e2e_sequential_writes e2e_sequential_writes_mid_sync e2e_all e2e_suite e2e_suite_silent e2e_suite_ipc e2e_suite_ipc_silent unit_gc_test unit_cache_membership_test unit_recovery_state_test unit_gc_test_run unit_cache_membership_test_run unit_recovery_state_test_run unit_all test_all bdus_startup perf_steady_state perf_steady_state_ipc perf_driver_steady_state_ipc perf_dual_ipc throughput_steady_state write_at_offset read_at_offset
.PHONY: e2e_flush e2e_recovery e2e_sync e2e_timelock_state e2e_timelock_durations e2e_freshness e2e_fs_mount_recovery e2e_gatekeeper_log_state e2e_driver_restart_recovery e2e_fs_timelock_recovery e2e_sequential_writes e2e_sequential_writes_mid_sync e2e_all e2e_suite e2e_suite_silent e2e_suite_ipc e2e_suite_ipc_silent unit_gc_test unit_cache_membership_test unit_recovery_state_test unit_gc_test_run unit_cache_membership_test_run unit_recovery_state_test_run unit_all test_all bdus_startup perf_steady_state perf_steady_state_ipc perf_driver_steady_state_ipc perf_dual_ipc throughput_steady_state

e2e_flush:
	@bash ./tests/e2e_gatekeeper_flush.sh

e2e_recovery:
	@bash ./tests/e2e_gatekeeper_recovery.sh

e2e_sync:
	@bash ./tests/e2e_sync_durability.sh

e2e_timelock_state:
	@bash ./tests/e2e_timelock_state_machine.sh

e2e_timelock_durations:
	@bash ./tests/e2e_timelock_durations.sh

e2e_freshness:
	@bash ./tests/e2e_freshness_counter.sh

e2e_fs_mount_recovery:
	@bash ./tests/e2e_fs_mount_recovery.sh

e2e_gatekeeper_log_state:
	@bash ./tests/e2e_gatekeeper_log_state.sh

e2e_driver_restart_recovery:
	@bash ./tests/e2e_driver_restart_recovery.sh

e2e_fs_timelock_recovery:
	@bash ./tests/e2e_fs_timelock_recovery.sh

e2e_sequential_writes:
	@bash ./tests/e2e_sequential_writes.sh

e2e_sequential_writes_mid_sync:
	@bash ./tests/e2e_sequential_writes_mid_sync.sh

bdus_startup:
	@bash ./startup_bdus_control.sh

e2e_suite:
	@bash ./tests/e2e_run_all.sh $(E2E_FLAGS)

e2e_suite_silent:
	@bash ./tests/e2e_run_all.sh --silent $(E2E_FLAGS)

perf_steady_state:
	@bash ./tests/perf_gatekeeper_steady_state.sh

perf_steady_state_ipc:
	@bash ./tests/perf_gatekeeper_steady_state_ipc.sh

perf_driver_steady_state_ipc:
	@bash ./tests/perf_driver_steady_state_ipc.sh

perf_dual_ipc:
	@bash ./tests/perf_dual_ipc.sh

throughput_steady_state:
	@bash ./tests/throughput_steady_state.sh

# Generic rules for compiling a source file to an object file
${BUILDDIR}/%.o: ${SRCDIR}/%.${SRCEXT}
	@mkdir -p ${BUILDDIR}
	${CC} ${CFLAGS} ${INC} -c -o $@ $<

test:
	@echo ${SOURCES}
	@echo ${OBJECTS}

shared:
	cd ../shared && $(MAKE) && cd ../versioning_td_driver

# Compile and tag this compilation
versioning_td_driver: ${OBJECTS}
	@echo $@
	@mkdir -p ${TARGETDIR}
	${CC} ${CFLAGS} ${INC} -o ${TARGETDIR}/$@ $^ ${BDUSFLAGS} ${LIBTHREAD} ${LIBRT}

unit_gc_test:
	@echo $@
	@mkdir -p ${TARGETDIR}
	${CC} ${CFLAGS} -DNO_NETWORK -DPHYSICAL_DISK_SIZE=$$((16 * 1024 * 1024)) -DLOGICAL_DISK_SIZE=$$((16 * 1024 * 1024)) -I ../shared/include -I include -pthread -o ${TARGETDIR}/$@ tests/unit_gc_test.c src/versioning.c src/socket_send.c src/ipc_transport.c ${LIBRT}

unit_cache_membership_test:
	@echo $@
	@mkdir -p ${TARGETDIR}
	${CC} ${CFLAGS} -DNO_NETWORK -DPHYSICAL_DISK_SIZE=$$((16 * 1024 * 1024)) -DLOGICAL_DISK_SIZE=$$((16 * 1024 * 1024)) -I ../shared/include -I include -pthread -o ${TARGETDIR}/$@ tests/unit_cache_membership_test.c src/versioning.c src/socket_send.c src/ipc_transport.c ${LIBRT}

unit_recovery_state_test:
	@echo $@
	@mkdir -p ${TARGETDIR}
	${CC} ${CFLAGS} -DNO_NETWORK -DPHYSICAL_DISK_SIZE=$$((16 * 1024 * 1024)) -DLOGICAL_DISK_SIZE=$$((16 * 1024 * 1024)) -I ../shared/include -I include -pthread -o ${TARGETDIR}/$@ tests/unit_recovery_state_test.c

unit_gc_test_run: unit_gc_test
	@./${TARGETDIR}/unit_gc_test

unit_cache_membership_test_run: unit_cache_membership_test
	@./${TARGETDIR}/unit_cache_membership_test

unit_recovery_state_test_run: unit_recovery_state_test
	@./${TARGETDIR}/unit_recovery_state_test

unit_all: $(UNIT_TEST_TARGETS)

test_all:
	@set -e; \
	targets="$(UNIT_TEST_TARGETS) $(E2E_TEST_TARGETS)"; \
	for t in $$targets; do \
		log_file="$${TMPDIR:-/tmp}/test_all.$${t}.$$$$.log"; \
		if ! $(MAKE) --no-print-directory $$t >"$$log_file" 2>&1; then \
			echo "[test_all] FAILED: $$t"; \
			cat "$$log_file"; \
			rm -f "$$log_file"; \
			exit 1; \
		fi; \
		rm -f "$$log_file"; \
	done

run:
	@sudo ./bin/versioning_td_driver --ipc > current_bdus.txt
	$(eval current_bdus = `cat current_bdus.txt`)
	@echo "Creating driver " ${current_bdus}
	@sudo mkfs.ext4 ${current_bdus}
# 	@sudo e2fsck ${current_bdus}
	@mkdir -p ${MOUNT_DIR}
	@sudo mount ${current_bdus} ${MOUNT_DIR}

run_baseline:
	@sudo ./bin/versioning_td_driver --baseline > current_bdus.txt
	$(eval current_bdus = `cat current_bdus.txt`)
	@echo "Creating driver " ${current_bdus}
	@sudo mkfs.ext4 ${current_bdus}
	@mkdir -p ${MOUNT_DIR}
	@sudo mount ${current_bdus} ${MOUNT_DIR}

run_no_fs:
	@sudo ./bin/versioning_td_driver | tee current_bdus.txt
	$(eval current_bdus = `cat current_bdus.txt`)
	@echo "Creating driver " ${current_bdus}

run_no_fs_baseline:
	@sudo ./bin/versioning_td_driver --baseline | tee current_bdus.txt
	$(eval current_bdus = `cat current_bdus.txt`)
	@echo "Creating driver " ${current_bdus}

run_trace:
	@test -n "$(TRACE_FILE)" || (echo "Usage: make run_trace TRACE_FILE=/path/to/trace.bin" >&2; exit 1)
	@sudo ./bin/versioning_td_driver --trace $(TRACE_FILE) --finish > current_bdus.txt
	$(eval current_bdus = `cat current_bdus.txt`)
	@echo "Creating driver " ${current_bdus}

run_km:
	@sudo ./bin/versioning_td_driver --timestamp 0 > current_bdus.txt
	$(eval current_bdus = `cat current_bdus.txt`)
	@echo "Creating driver " ${current_bdus}

	@echo "Fixing anything broken by bad unmount" ${current_bdus}
	@sudo fsck ${current_bdus} -y || true
	@sudo mount ${current_bdus} ${MOUNT_DIR}

clean:
	@echo "Cleaning..."
	@mkdir -p ${BUILDDIR}
	@mkdir -p ${TARGETDIR}
	@sudo rm -rf ${BUILDDIR} ${TARGETDIR}
	@echo "Removing " ${current_bdus}
	@sudo bdus destroy --no-flush ${current_bdus} || true
	@echo "Removed " ${current_bdus}
	@sudo ./cleanup_lingering_stack.sh
# @echo "Kill processes using the mount"
# @sudo fuser -cuk /mnt
# @echo "All processes killed"
	@echo "Unmounting..."
	@sudo umount -f ${MOUNT_DIR} || true
	@echo "Unmounted..."
	@echo "Removing mount dir..."
	@sudo rm -r ${MOUNT_DIR} || true
	@echo "Removed mount dir..."

clean_km:
	@echo "Cleaning..."
	@mkdir -p ${BUILDDIR}
	@mkdir -p ${TARGETDIR}
	@rm -r ${BUILDDIR} ${TARGETDIR}
	@echo "Removing " ${current_bdus}
	@sudo bdus destroy ${current_bdus}
