// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef AJAR_AUDIO_ATOMICS_H
#define AJAR_AUDIO_ATOMICS_H

#include <stdint.h>

typedef struct AjarAudioAtomicUInt64 AjarAudioAtomicUInt64;

AjarAudioAtomicUInt64 *AjarAudioAtomicUInt64Create(uint64_t initialValue);
void AjarAudioAtomicUInt64Destroy(AjarAudioAtomicUInt64 *atomicValue);
int AjarAudioAtomicUInt64IsLockFree(const AjarAudioAtomicUInt64 *atomicValue);
uint64_t AjarAudioAtomicUInt64LoadAcquire(const AjarAudioAtomicUInt64 *atomicValue);
void AjarAudioAtomicUInt64StoreRelease(AjarAudioAtomicUInt64 *atomicValue, uint64_t value);
uint64_t AjarAudioAtomicUInt64LoadSeqCst(const AjarAudioAtomicUInt64 *atomicValue);
void AjarAudioAtomicUInt64StoreSeqCst(AjarAudioAtomicUInt64 *atomicValue, uint64_t value);

#endif
