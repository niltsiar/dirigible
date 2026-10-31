// This file is from Dirigible, not from whisper.cpp (decision 0065).
#include "cwhisper_stop.h"

#include "ggml.h"

#include <stdatomic.h>
#include <stdlib.h>

// The flag guards no other data, so relaxed loads and stores are enough.
struct cwhisper_stop {
    atomic_bool set;
};

cwhisper_stop * cwhisper_stop_new(void) {
    cwhisper_stop * flag = malloc(sizeof(cwhisper_stop));
    if (flag != NULL) {
        atomic_init(&flag->set, false);
    }
    return flag;
}

void cwhisper_stop_free(cwhisper_stop * flag) {
    free(flag);
}

void cwhisper_stop_set(cwhisper_stop * flag) {
    atomic_store_explicit(&flag->set, true, memory_order_relaxed);
}

bool cwhisper_stop_is_set(const cwhisper_stop * flag) {
    return atomic_load_explicit(&flag->set, memory_order_relaxed);
}

bool cwhisper_stop_abort(void * flag) {
    return cwhisper_stop_is_set(flag);
}

_Static_assert(_Generic(&cwhisper_stop_abort, ggml_abort_callback: 1, default: 0), "cwhisper_stop_abort is a ggml_abort_callback");
