#include "MainStack.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

ms_thread ms_thread_current(void) {
    pthread_t self = pthread_self();
    uintptr_t high = (uintptr_t)pthread_get_stackaddr_np(self);
    return (ms_thread){pthread_mach_thread_np(self), high - pthread_get_stacksize_np(self), high};
}

uintptr_t ms_strip_pac(uintptr_t address) { return address & 0x00007FFFFFFFFFFFULL; }

static uintptr_t code_address(uintptr_t address) {
#if defined(__arm64__)
    return ms_strip_pac(address);
#else
    return address;
#endif
}

ms_walk_result ms_walk(ms_thread thread, uintptr_t *frames, int capacity) {
    ms_walk_result result = {KERN_INVALID_ARGUMENT, 0, 0, 0};
    if (capacity < 1 || thread.port == pthread_mach_thread_np(pthread_self()))
        return result;
    kern_return_t status = thread_suspend(thread.port);
    if (status != KERN_SUCCESS) {
        result.status = status;
        return result;
    }
    result.suspended_at = mach_absolute_time();
#if defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    status = thread_get_state(thread.port, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    uintptr_t pc = state.__rip, fp = state.__rbp;
#elif defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    status = thread_get_state(thread.port, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    uintptr_t pc = arm_thread_state64_get_pc(state), fp = arm_thread_state64_get_fp(state);
#else
#error "CMainStack walks x86_64 and arm64 only"
#endif
    int saved = 0;
    if (status == KERN_SUCCESS) {
        frames[saved++] = code_address(pc);
        // A frame record is the next record and the return address. The chain pointer is not
        // signed, so only the return address gets the mask.
        while (saved < capacity && fp >= thread.stack_low && fp + 2 * sizeof(uintptr_t) <= thread.stack_high &&
               (fp & (sizeof(uintptr_t) - 1)) == 0) {
            uintptr_t next = ((const uintptr_t *)fp)[0];
            uintptr_t back = code_address(((const uintptr_t *)fp)[1]);
            if (back == 0) break;
            frames[saved++] = back;
            if (next <= fp) break;
            fp = next;
        }
    }
    result.resumed_at = mach_absolute_time();
    thread_resume(thread.port);
    result.status = status;
    result.count = status == KERN_SUCCESS ? saved : 0;
    return result;
}

// The image list: one slot for each image that dyld reports, taken with an atomic add. The
// callback can run on any thread, the main thread too, while another thread reads the list.

#define MS_IMAGES 4096

typedef struct {
    uintptr_t header;
    intptr_t slide;
    uint8_t uuid[16];
    atomic_bool ready;
} ms_image_slot;

static ms_image_slot slots[MS_IMAGES];
static atomic_int taken;
static atomic_int dropped;
static atomic_flag registered = ATOMIC_FLAG_INIT;

static void added(const struct mach_header *header, intptr_t slide) {
    int index = atomic_fetch_add_explicit(&taken, 1, memory_order_relaxed);
    if (index >= MS_IMAGES) {
        atomic_fetch_add_explicit(&dropped, 1, memory_order_relaxed);
        return;
    }
    ms_image_slot *slot = &slots[index];
    slot->header = (uintptr_t)header;
    slot->slide = slide;
    const uint8_t *command = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmd == LC_UUID) {
            memcpy(slot->uuid, ((const struct uuid_command *)load)->uuid, sizeof(slot->uuid));
            break;
        }
        command += load->cmdsize;
    }
    atomic_store_explicit(&slot->ready, true, memory_order_release);
}

void ms_images_start(void) {
    if (!atomic_flag_test_and_set(&registered)) _dyld_register_func_for_add_image(added);
}

int ms_images_count(void) {
    int count = atomic_load_explicit(&taken, memory_order_acquire);
    return count < MS_IMAGES ? count : MS_IMAGES;
}

int ms_images_dropped(void) { return atomic_load_explicit(&dropped, memory_order_acquire); }

bool ms_image_at(int index, uintptr_t *header, intptr_t *slide, uint8_t uuid[16]) {
    if (index < 0 || index >= MS_IMAGES || !atomic_load_explicit(&slots[index].ready, memory_order_acquire))
        return false;
    *header = slots[index].header;
    *slide = slots[index].slide;
    memcpy(uuid, slots[index].uuid, sizeof(slots[index].uuid));
    return true;
}
