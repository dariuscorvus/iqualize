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

// Render-thread snapshot publication primitives. A publisher initializes a
// complete snapshot, exchanges it with acq_rel ordering, then waits for the
// reader count to reach zero before reclaiming the old snapshot. A reader must
// increment readers with acq_rel ordering before loading current with acquire
// ordering, and decrement with release ordering after it stops dereferencing
// the snapshot. This ordering closes the race where a callback starts while a
// publisher is retiring the previous pointer: callbacks that can still see the
// old pointer are counted before the publisher observes quiescence.
static inline void *iq_load_acquire_ptr(void * const *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void *iq_exchange_acq_rel_ptr(void **p, void *v) {
    return __atomic_exchange_n(p, v, __ATOMIC_ACQ_REL);
}

static inline uint32_t iq_load_acquire_u32(const uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline uint32_t iq_fetch_add_acq_rel_u32(uint32_t *p, uint32_t v) {
    return __atomic_fetch_add(p, v, __ATOMIC_ACQ_REL);
}

static inline uint32_t iq_fetch_sub_release_u32(uint32_t *p, uint32_t v) {
    return __atomic_fetch_sub(p, v, __ATOMIC_RELEASE);
}

#endif /* IQ_RING_ATOMICS_H */
