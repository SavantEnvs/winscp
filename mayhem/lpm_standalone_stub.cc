#include <stddef.h>
#include <stdint.h>
// The standalone reproducer links no libFuzzer runtime; libprotobuf-mutator's custom mutator
// (never invoked by the run-once driver) references this symbol.
extern "C" size_t LLVMFuzzerMutate(uint8_t *, size_t size, size_t) { return size; }
