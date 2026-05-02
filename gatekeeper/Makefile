# Based on https://hiltmon.com/blog/2013/07/03/a-simple-c-plus-plus-project-structure/
dafny_exec := $(shell command -v dafny 2>/dev/null || echo /opt/dafny/dafny)
pypy_exec := ../../pypy3.10-v7.3.17-linux64/bin/pypy
BUILDDIR := main-rust
FS_FILE := disk_file
TARGET_DIR := gatekeeper
OPT_DIR := gatekeeper-opt
dafny_files := $(shell find $(TARGET_DIR) -name '*.dfy')

all: verify build run
opt: swap verify build run
build_opt: swap build
run_opt: swap2 run
run_opt_no_init: swap2 run_no_init
run_baseline_opt_no_init: swap2 run_baseline_no_init
run_baseline_opt: swap2 run_baseline

swap: swap1 swap2 swap3

swap1:
	@cp -r ${TARGET_DIR} ${OPT_DIR}

swap2:
	$(eval TARGET_DIR = $(OPT_DIR))
	$(eval dafny_files := $(shell find $(TARGET_DIR) -name '*.dfy'))

swap3:
	@python3 constants_optimizer.py ${OPT_DIR}/constants.dfy
	@python3 constants_optimizer.py ${OPT_DIR}/std-library.dfy

verify:
	$(foreach file,$(dafny_files), echo ${file}; ${dafny_exec} verify --cores:8 $(file);)

build:
	${dafny_exec} resolve --allow-warnings --function-syntax:3 ${TARGET_DIR}/main.dfy
	${dafny_exec} build --target:rs --no-verify --allow-warnings --function-syntax:3 ${TARGET_DIR}/main.dfy | true
	@mkdir -p ${TARGET_DIR}/main-rust/src/
	cat rust-externs/externs.rs >> ${TARGET_DIR}/main-rust/src/main.rs
	@if ! grep -q "^\[package\]" ${TARGET_DIR}/main-rust/Cargo.toml 2>/dev/null; then \
		printf "[package]\nname = \"main\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\ndafny_runtime = { path = \"runtime\" }\n\n[[bin]]\nname = \"main\"\npath = \"src/main.rs\"\n" > ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^\[profile.dev\]" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		printf "\n[profile.dev]\nopt-level = 3\n\n[profile.release]\nopt-level = 3\nlto = true\ncodegen-units = 1\nstrip = \"debuginfo\"\npanic = \"abort\"\n" >> ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^lazy_static\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a lazy_static = "1"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^libc\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a libc = "0.2"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^tick_counter\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a tick_counter = "0.4"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^pakr-rawata\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a pakr-rawata = "1"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^rand\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a rand = "0.10"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^blake3\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a blake3 = "1"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	@if ! grep -q "^constant_time_eq\s*=\s*" ${TARGET_DIR}/main-rust/Cargo.toml; then \
		sed -i '/^\[dependencies\]$$/a constant_time_eq = "=0.4.2"' ${TARGET_DIR}/main-rust/Cargo.toml; \
	fi
	cd ${TARGET_DIR}/main-rust/ && cargo build --release && cd ../..
# 	&& cargo add pakr-rawata
#   && cargo add scsir

run:
	sudo ./gatekeeper/main-rust/target/release/main --timelockdrive --ipc

run_baseline:
	sudo -E ${pypy_exec} ${TARGET_DIR}/main-py/__main__.py --baseline

run_no_init:
	sudo -E ${pypy_exec} ${TARGET_DIR}/main-py/__main__.py --no-init

run_baseline_no_init:
	sudo -E ${pypy_exec} ${TARGET_DIR}/main-py/__main__.py --baseline --no-init

clean:
	@echo "Cleaning..."
	@mkdir -p ${BUILDDIR}
	@mkdir -p ${OPT_DIR}
	@rm -rf ${BUILDDIR}
	@rm -rf ${OPT_DIR} || true
	@rm -rf ${TARGET_DIR}/main-rust/ || true
	@echo "Clean"
