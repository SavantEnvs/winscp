#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
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

RUNTESTS="$SRC/mayhem/build-test/tests/runtests"
XMLWF="$SRC/mayhem/build-test/xmlwf/xmlwf"
[ -x "$RUNTESTS" ] || { echo "missing $RUNTESTS (mayhem/build.sh should have built it)" >&2; emit_ctrf "expat-runtests" 0 1; exit 1; }
[ -x "$XMLWF" ] || { echo "missing $XMLWF (mayhem/build.sh should have built it)" >&2; emit_ctrf "expat-runtests" 0 1; exit 1; }

passed=0; failed=0

# 1) Expat's own unit suite. Its summary line is "NN%: Checks: N, Failed: F"; a neutered or
#    crashed runner prints nothing, so the match fails and the run is counted as a failure.
out="$("$RUNTESTS" 2>&1)"; rc=$?
echo "$out" | tail -n 5
if [[ "$out" =~ Checks:\ ([0-9]+),\ Failed:\ ([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 1000 ]; then
  checks="${BASH_REMATCH[1]}"; nfail="${BASH_REMATCH[2]}"
  passed=$(( passed + checks - nfail )); failed=$(( failed + nfail ))
  [ "$rc" -eq 0 ] || failed=$(( failed + 1 ))
else
  echo "runtests produced no usable summary (rc=$rc)" >&2; failed=$(( failed + 1 ))
fi

# 2) Known-answer probes through xmlwf (dynamically linked, so the sabotage shim can neuter it):
#    fixed input -> asserted canonical output / meta output / diagnostic + exit status.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '<?xml version="1.0"?>\n<!DOCTYPE r [<!ENTITY e "hello">]>\n<r b="2" a="1"><c>&e; world &#65;</c><d/></r>\n' > "$T/t.xml"
printf '<r><a></r>' > "$T/bad.xml"
mkdir "$T/o"

kat() { # <name> <expected> <actual>
  if [ "$2" == "$3" ]; then passed=$(( passed + 1 )); else
    failed=$(( failed + 1 )); echo "KAT FAIL: $1" >&2; echo "  expected: $2" >&2; echo "  actual:   $3" >&2; fi
}

"$XMLWF" -d "$T/o" "$T/t.xml"; rc=$?
kat "xmlwf canonical rc" "0" "$rc"
kat "xmlwf canonical output (entities expanded, attributes sorted, empty tags expanded)" \
    '<r a="1" b="2"><c>hello world A</c><d></d></r>' "$(cat "$T/o/t.xml" 2>/dev/null)"

"$XMLWF" -m -d "$T/o" "$T/t.xml"
kat "xmlwf meta output: entity decl and chars" "yes" \
    "$(grep -q '<entity name="e" .*>hello</entity/>' "$T/o/t.xml" && grep -q '<chars str=" world "' "$T/o/t.xml" && echo yes || echo no)"
kat "xmlwf meta output: attribute order preserved" '<attribute name="b" value="2"/>|<attribute name="a" value="1"/>' \
    "$(grep '<attribute' "$T/o/t.xml" | paste -sd'|')"

msg="$("$XMLWF" "$T/bad.xml" 2>&1)"; rc=$?
kat "xmlwf rejects mismatched tag (rc)" "2" "$rc"
kat "xmlwf rejects mismatched tag (message)" "$T/bad.xml:1:8: mismatched tag" "$msg"

emit_ctrf "expat-runtests+xmlwf-kat" "$passed" "$failed"
