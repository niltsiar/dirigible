// The stop flag of one transcription (decision 0065). This file is from Dirigible, not from
// whisper.cpp.
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cwhisper_stop cwhisper_stop;

/// A new flag that is clear, or NULL when the allocation fails.
cwhisper_stop * cwhisper_stop_new(void);

/// Frees the flag. No call may read the flag after this one.
void cwhisper_stop_free(cwhisper_stop * flag);

/// Sets the flag. Any thread can call it.
void cwhisper_stop_set(cwhisper_stop * flag);

bool cwhisper_stop_is_set(const cwhisper_stop * flag);

/// The abort callback of whisper_full, with a cwhisper_stop as its data: it returns true when the
/// flag is set. It does not allocate, lock, or call Swift, so it can run on the compute thread.
bool cwhisper_stop_abort(void * flag);

#ifdef __cplusplus
}
#endif
