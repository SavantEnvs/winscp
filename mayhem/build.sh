#!/usr/bin/env bash
#
# mayhem/build.sh — build WinSCP's fuzzable code: the bundled Expat XML parser (libs/expat).
# WinSCP itself is a Windows GUI/VCL application; the only portable, buildable fuzz surface in the tree
# is libs/expat, whose own harnesses (libs/expat/fuzz/) are the ones ported here.
#
# Runs in the commit image as `mayhem` in /mayhem; re-runnable and air-gapped (no network, no installs).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
EXPAT="$SRC/libs/expat"
HERE="$SRC/mayhem"
OUT="$SRC"

# --- 1) Sanitized + coverage-instrumented Expat (static), with DWARF <= 3. -----------------------
# -fsanitize=fuzzer-no-link gives the library SanCov edges (without it Mayhem records 0 edges).
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"
cmake -S "$EXPAT" -B "$HERE/build-fuzz" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" \
  -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_TOOLS=OFF \
  -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_PKGCONFIG=OFF >/dev/null
cmake --build "$HERE/build-fuzz" -j"$MAYHEM_JOBS"
LIBEXPAT="$(ls "$HERE"/build-fuzz/libexpat*.a | head -n1)"

# --- 2) Harnesses: libFuzzer binary + non-fuzzer standalone reproducer, per encoding. ----------
# Leak detection is compiled out (lsan_off.cc); ASan + UBSan stay on and halting.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HERE/lsan_off.cc" -o "$HERE/build-fuzz/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$HERE/build-fuzz/standalone_main.o"

build_harness() { # <name> <source> <encoding>
  local name="$1" srcf="$2" enc="$3"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DENCODING_FOR_FUZZING="$enc" \
    -I"$EXPAT/lib" -I"$HERE/build-fuzz" $LIB_FUZZING_ENGINE \
    "$srcf" "$LIBEXPAT" "$HERE/build-fuzz/lsan_off.o" -o "$OUT/$name"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DENCODING_FOR_FUZZING="$enc" \
    -I"$EXPAT/lib" -I"$HERE/build-fuzz" \
    "$srcf" "$HERE/build-fuzz/standalone_main.o" "$LIBEXPAT" "$HERE/build-fuzz/lsan_off.o" \
    -o "$OUT/$name-standalone"
}

for e in utf8:UTF-8 utf16:UTF-16 utf16be:UTF-16BE utf16le:UTF-16LE iso8859_1:ISO-8859-1 us_ascii:US-ASCII; do
  for h in parse parsebuffer; do
    build_harness "xml_${h}_fuzzer_${e%%:*}" "$EXPAT/fuzz/xml_${h}_fuzzer.c" "${e#*:}"
  done
done

# xml_lpm_fuzzer: structured (libprotobuf-mutator) harness. LPM is pre-built into the image by
# mayhem/Dockerfile (pinned commit) so this step needs no network.
LPM_ROOT="${LPM_ROOT:-/opt/toolchains/libprotobuf-mutator}"
protoc --cpp_out="$HERE/build-fuzz" -I"$EXPAT/fuzz" "$EXPAT/fuzz/xml_lpm_fuzzer.proto"
LPM_FLAGS="-std=c++17 -I$LPM_ROOT/src -I$EXPAT/lib -I$HERE/build-fuzz"
LPM_LIBS="$LPM_ROOT/build/src/libfuzzer/libprotobuf-mutator-libfuzzer.a $LPM_ROOT/build/src/libprotobuf-mutator.a -lprotobuf"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $LPM_FLAGS $LIB_FUZZING_ENGINE \
  "$EXPAT/fuzz/xml_lpm_fuzzer.cpp" "$HERE/build-fuzz/xml_lpm_fuzzer.pb.cc" \
  "$LIBEXPAT" $LPM_LIBS "$HERE/build-fuzz/lsan_off.o" -o "$OUT/xml_lpm_fuzzer"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $LPM_FLAGS \
  "$EXPAT/fuzz/xml_lpm_fuzzer.cpp" "$HERE/build-fuzz/xml_lpm_fuzzer.pb.cc" \
  "$HERE/lpm_standalone_stub.cc" "$HERE/build-fuzz/standalone_main.o" \
  "$LIBEXPAT" $LPM_LIBS "$HERE/build-fuzz/lsan_off.o" -o "$OUT/xml_lpm_fuzzer-standalone"

# --- 3) The project's own test suite (runtests) + xmlwf, with NORMAL flags (no sanitizer, no DWARF pin). ---
cmake -S "$EXPAT" -B "$HERE/build-test" \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
  -DEXPAT_SHARED_LIBS=OFF -DEXPAT_BUILD_TESTS=ON -DEXPAT_BUILD_TOOLS=ON \
  -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_PKGCONFIG=OFF >/dev/null
cmake --build "$HERE/build-test" -j"$MAYHEM_JOBS" --target runtests xmlwf
