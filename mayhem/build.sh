#!/usr/bin/env bash
#
# mayhem/build.sh — builds the three fuzz harnesses (+ run-once reproducers) and the test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Dependencies (Qt, the pinned MAVLink
# generator, the CPM source cache) live under /opt/toolchains; the first (online) run fills the CPM cache and every
# later run, including the air-gapped PATCH rebuild, resolves from it.
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
: "${CPM_SOURCE_CACHE:=/opt/toolchains/cpm}"
export CPM_SOURCE_CACHE
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# MAVLink C headers for the pinned dialect, generated into a gitignored build dir.
CFG="$SRC/cmake/CustomOptions.cmake"
DIALECT=$(python3 "$SRC/.clusterfuzzlite/read_mavlink_config.py" "$CFG" DIALECT)
WIRE=$(python3 "$SRC/.clusterfuzzlite/read_mavlink_config.py" "$CFG" VERSION)
MAV_INC="$SRC/build-mayhem-mavlink/include"
rm -rf "$SRC/build-mayhem-mavlink"
PYTHONPATH="$MAVLINK_SRC" python3 -S -m pymavlink.tools.mavgen --no-validate --lang=C \
    --wire-protocol="$WIRE" --output "$MAV_INC/mavlink" "$MAVLINK_SRC/message_definitions/v1.0/$DIALECT.xml" >/dev/null
MAV_FLAGS="-std=c++20 -I$MAV_INC/mavlink -I$MAV_INC/mavlink/$DIALECT"

rm -rf build-mayhem-fuzz build-mayhem-tests

# 1) Sanitized fuzz build: QGCGPSCore/QGCNTRIPHttp (and the GPS support libraries) under ASan+UBSan+fuzzer-no-link.
cmake -S mayhem/cmake -B build-mayhem-fuzz -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DMAYHEM_FUZZ=ON -DMAYHEM_STANDALONE_MAIN="$STANDALONE_FUZZ_MAIN"
cmake --build build-mayhem-fuzz -j"$MAYHEM_JOBS" --target \
    QGCGPSProtocolFuzz ntrip_http_decoder_fuzzer \
    gps_protocol_fuzz_standalone ntrip_http_decoder_fuzzer_standalone
cp build-mayhem-fuzz/standalone/ProtocolFuzz/QGCGPSProtocolFuzz "$SRC/gps_protocol_fuzz"
cp build-mayhem-fuzz/standalone/NTRIPHttpFuzz/ntrip_http_decoder_fuzzer "$SRC/ntrip_http_decoder_fuzzer"
cp build-mayhem-fuzz/gps_protocol_fuzz_standalone "$SRC/gps_protocol_fuzz-standalone"
cp build-mayhem-fuzz/ntrip_http_decoder_fuzzer_standalone "$SRC/ntrip_http_decoder_fuzzer-standalone"

# 2) MAVLink parser harness: header-only, so the harness TU carries all the instrumentation.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-mayhem-mavlink/standalone_main.o
$CXX -c $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link mayhem/lsan_off.cc -o build-mayhem-mavlink/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $MAV_FLAGS $LIB_FUZZING_ENGINE test/Fuzz/MAVLinkParserFuzzer.cc \
    build-mayhem-mavlink/lsan_off.o -o "$SRC/mavlink_parser_fuzzer"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $MAV_FLAGS test/Fuzz/MAVLinkParserFuzzer.cc \
    build-mayhem-mavlink/standalone_main.o build-mayhem-mavlink/lsan_off.o -o "$SRC/mavlink_parser_fuzzer-standalone"

# 3) Test oracle with the project's NORMAL flags: the GPS runner + NTRIP smoke from test/GPS/Standalone, a
#    known-answer NTRIP decoder check and a MAVLink round-trip check. test.sh only runs them.
cmake -S mayhem/cmake -B build-mayhem-tests -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_PREFIX_PATH="$QT_PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-mayhem-tests -j"$MAYHEM_JOBS" --target \
    QGCGPSHardwareRunner ntrip_http_decoder_smoke ntrip_decoder_selftest
$CXX -O2 $COVERAGE_FLAGS $MAV_FLAGS mayhem/tests/mavlink_selftest.cc -o build-mayhem-tests/mavlink_selftest
