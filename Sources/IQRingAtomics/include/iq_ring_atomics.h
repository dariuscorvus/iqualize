#ifndef IQ_RING_ATOMICS_H
#define IQ_RING_ATOMICS_H

#include <stdint.h>

// 64-bit acquire/release pair for the capture ring's head fields, shared
// between the iQualizeCapture helper (writer) and the app (reader) across a
// MAP_SHARED mapping. The writer's release-store of writeHead pairs with the
// reader's acquire-load so sample data written before the store is visible
// after the load — plain loads/stores give no such guarantee on arm64.
//
// Clang __atomic builtins on plain uint64_t* (not _Atomic types): valid on
// any naturally aligned 64-bit field, importable into Swift as ordinary
// functions, and dependency-free. Both head fields sit at offsets 0 and 8 of
// a page-aligned mapping, so alignment always holds.

static inline uint64_t iq_load_acquire_u64(const uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void iq_store_release_u64(uint64_t *p, uint64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

// Relaxed variants for single-writer telemetry counters: torn-free, no
// ordering — readers only need eventually-consistent whole values.
static inline uint64_t iq_load_relaxed_u64(const uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_RELAXED);
}

static inline void iq_store_relaxed_u64(uint64_t *p, uint64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELAXED);
}

#endif /* IQ_RING_ATOMICS_H */
