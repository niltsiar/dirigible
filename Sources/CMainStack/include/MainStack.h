// The stack walk and the image list of the hang watchdog (decision 0059). Between the suspend and
// the resume, and in the image callback, no function allocates, takes a lock, or logs: a suspended
// main thread can hold the malloc, dyld, or Swift runtime lock.
#ifndef MAIN_STACK_H
#define MAIN_STACK_H

#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>

/// A thread to walk: its port and the bounds of its stack.
typedef struct {
    mach_port_t port;
    uintptr_t stack_low;
    uintptr_t stack_high;
} ms_thread;

/// The result of one walk. `suspended_at` and `resumed_at` are `mach_absolute_time` ticks: the
/// window in which the thread was suspended. `count` is 0 when `status` is not `KERN_SUCCESS`.
typedef struct {
    kern_return_t status;
    int count;
    uint64_t suspended_at;
    uint64_t resumed_at;
} ms_walk_result;

/// The calling thread. The macOS SDK has no call that gives the main thread from another thread,
/// so the watchdog takes it on the main thread.
ms_thread ms_thread_current(void);

/// Suspends `thread`, saves its pc and the return address of each frame-pointer record inside
/// its stack bounds into `frames` (at most `capacity`), and resumes it. When the pc follows a
/// system call instruction, the second frame is the caller of that stub, which has no record.
/// A walk of the calling thread returns `KERN_INVALID_ARGUMENT` with no suspend.
ms_walk_result ms_walk(ms_thread thread, uintptr_t *frames, int capacity);

/// Clears the pointer-authentication bits of an arm64e code address: the bits above the 47-bit
/// user space of macOS (`MACH_VM_MAX_ADDRESS_RAW` in `mach/arm/vm_param.h`). The walk calls it on
/// arm64 only.
uintptr_t ms_strip_pac(uintptr_t address);

/// Registers the image callback once for each process. dyld calls it for each loaded image during
/// this call, and later for each new image on the thread that loads it.
void ms_images_start(void);

/// The slots that the callback took, at most the 4096 slots of the list.
int ms_images_count(void);

/// The images that found no free slot.
int ms_images_dropped(void);

/// The mach header address, the slide, and the `LC_UUID` of the image in slot `index`. False when
/// the callback has not finished the slot.
bool ms_image_at(int index, uintptr_t *header, intptr_t *slide, uint8_t uuid[16]);

#endif
