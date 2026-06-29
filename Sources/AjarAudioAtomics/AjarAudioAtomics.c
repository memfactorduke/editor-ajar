// SPDX-License-Identifier: GPL-3.0-or-later

#include "AjarAudioAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct AjarAudioAtomicUInt64 {
    _Atomic(uint64_t) value;
};

AjarAudioAtomicUInt64 *AjarAudioAtomicUInt64Create(uint64_t initialValue) {
    AjarAudioAtomicUInt64 *atomicValue = malloc(sizeof(AjarAudioAtomicUInt64));
    if (atomicValue == NULL) {
        return NULL;
    }

    atomic_init(&atomicValue->value, initialValue);
    return atomicValue;
}

void AjarAudioAtomicUInt64Destroy(AjarAudioAtomicUInt64 *atomicValue) {
    free(atomicValue);
}

int AjarAudioAtomicUInt64IsLockFree(const AjarAudioAtomicUInt64 *atomicValue) {
    return atomic_is_lock_free(&atomicValue->value) ? 1 : 0;
}

uint64_t AjarAudioAtomicUInt64LoadAcquire(const AjarAudioAtomicUInt64 *atomicValue) {
    return atomic_load_explicit(&atomicValue->value, memory_order_acquire);
}

void AjarAudioAtomicUInt64StoreRelease(AjarAudioAtomicUInt64 *atomicValue, uint64_t value) {
    atomic_store_explicit(&atomicValue->value, value, memory_order_release);
}

void AjarAudioAtomicThreadFenceSeqCst(void) {
    atomic_thread_fence(memory_order_seq_cst);
}
