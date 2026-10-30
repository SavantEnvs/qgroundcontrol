#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the functional checks that mayhem/build.sh built (normal flags, not the fuzz build).
# exit 0 = pass. Every check asserts output that a no-op program cannot produce.
#
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


T="$SRC/build-mayhem-tests"
passed=0 failed=0

# check <name> <regex the combined output must match> <command...>: unconditional (a missing binary fails).
check() {
  local name="$1" pattern="$2"; shift 2
  local out
  if out=$("$@" 2>&1) && grep -Eq -- "$pattern" <<<"$out"; then
    echo "PASS $name: $(grep -Eo -- "$pattern" <<<"$out" | head -1)"; passed=$((passed + 1))
  else
    echo "FAIL $name"; echo "$out" | tail -20; failed=$((failed + 1))
  fi
}

# The receiver qualification runner against a scripted receiver (check_runner.py parses and asserts its JSON reports).
check gps-hardware-runner '100% tests passed, 0 tests failed out of 1' \
  ctest --test-dir "$T" -R '^GPSHardwareRunner\.Scripted$' --output-on-failure
# Upstream's NTRIP decoder smoke: every seed shape and truncation passes through the decoder's own invariants.
check ntrip-decoder-smoke 'NTRIP HTTP fuzz smoke: [1-9][0-9]+ seeds' "$T/standalone/NTRIPHttpFuzz/ntrip_http_decoder_smoke"
# Known-answer decoding (status line, Content-Length, chunked, ICY, conflicting framing).
check ntrip-decoder-known-answers 'NTRIP decoder selftest: [1-9][0-9]+ checks passed' "$T/ntrip_decoder_selftest"
# MAVLink 2 pack/parse round trip and CRC rejection.
check mavlink-roundtrip 'MAVLink selftest: [1-9][0-9]+ checks passed' "$T/mavlink_selftest"

emit_ctrf "mayhem-selftests" "$passed" "$failed" 0
