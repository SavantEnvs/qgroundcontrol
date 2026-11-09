#!/usr/bin/env bash
#
# mayhem/build.sh — builds the ImageProtocolManager fuzz harness (+ run-once reproducer) and the test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Dependencies (Qt, the pinned MAVLink
# generator) live under /opt/toolchains, so the air-gapped PATCH rebuild resolves them without a network.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS


cd "$SRC"
: "${QT_PREFIX:=/opt/toolchains/qt/prefix}" "${MAVLINK_SRC:=/opt/toolchains/mavlink}"
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"

# MAVLink C headers for the pinned dialect, generated into a gitignored build dir.
CFG="$SRC/cmake/CustomOptions.cmake"
DIALECT=$(python3 "$SRC/mayhem/read_mavlink_config.py" "$CFG" DIALECT)
WIRE=$(python3 "$SRC/mayhem/read_mavlink_config.py" "$CFG" VERSION)
MAV_INC="$SRC/build-mayhem-mavlink/include"
rm -rf "$SRC/build-mayhem-mavlink"
PYTHONPATH="$MAVLINK_SRC" python3 -S -m pymavlink.tools.mavgen --no-validate --lang=C \
    --wire-protocol="$WIRE" --output "$MAV_INC/mavlink" "$MAVLINK_SRC/message_definitions/v1.0/$DIALECT.xml" >/dev/null
MAV_DIRS="$MAV_INC/mavlink;$MAV_INC/mavlink/$DIALECT"

rm -rf build-mayhem-fuzz build-mayhem-tests

# 1) Sanitized fuzz build: ImageProtocolManager.cc itself under ASan+UBSan+coverage, plus the run-once reproducer.
cmake -S mayhem -B build-mayhem-fuzz -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
    -DMAYHEM_FUZZ=ON -DMAYHEM_STANDALONE_MAIN="$STANDALONE_FUZZ_MAIN" -DMAYHEM_MAVLINK_INCLUDE="$MAV_DIRS" \
    -DMAYHEM_FUZZ_ENGINE="$LIB_FUZZING_ENGINE"
cmake --build build-mayhem-fuzz -j"$MAYHEM_JOBS" --target image_protocol_fuzzer image_protocol_fuzzer_standalone
cp build-mayhem-fuzz/image_protocol_fuzzer "$SRC/image_protocol_fuzzer"
cp build-mayhem-fuzz/image_protocol_fuzzer_standalone "$SRC/image_protocol_fuzzer-standalone"

# 2) Test oracle with the project's NORMAL flags (no sanitizers, no coverage unless COVERAGE_FLAGS): test.sh only runs it.
cmake -S mayhem -B build-mayhem-tests -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DMAYHEM_MAVLINK_INCLUDE="$MAV_DIRS"
cmake --build build-mayhem-tests -j"$MAYHEM_JOBS" --target image_protocol_selftest
