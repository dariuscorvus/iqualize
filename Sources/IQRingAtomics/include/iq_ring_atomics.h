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

// Render-thread snapshot publication primitives. The reader-count protocol
// uses one sequentially consistent order for the reader increment, pointer
// load, publisher exchange, and quiescence load:
//
//   reader:    increment readers; load current; ...; decrement readers
//   publisher: exchange current; load readers; reclaim only when zero
//
// If the reader loads the retired pointer, its increment is ordered before the
// publisher's quiescence load. If its increment is ordered after that load,
// its pointer load is ordered after the exchange and it sees the replacement.
// Acquire/release alone does not establish that total order on arm64.
static inline void *iq_load_snapshot_ptr(void * const *p) {
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

static inline void *iq_exchange_snapshot_ptr(void **p, void *v) {
    return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST);
}

static inline uint32_t iq_load_snapshot_readers(const uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

static inline uint32_t iq_enter_snapshot_reader(uint32_t *p) {
    return __atomic_fetch_add(p, 1, __ATOMIC_SEQ_CST);
}

static inline uint32_t iq_leave_snapshot_reader(uint32_t *p) {
    return __atomic_fetch_sub(p, 1, __ATOMIC_SEQ_CST);
}

static inline uint32_t iq_load_snapshot_u32(const uint32_t *p) {
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

static inline void iq_store_snapshot_u32(uint32_t *p, uint32_t v) {
    __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
}

#endif /* IQ_RING_ATOMICS_H */
