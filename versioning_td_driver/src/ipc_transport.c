/*
 * ipc_transport.c – shared-memory SPSC ring-buffer IPC transport.
 *
 * See include/ipc_transport.h for the design notes.
 */

#include "ipc_transport.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* IPC_RING_CAP must be a power of two for the index-masking trick. */
_Static_assert((IPC_RING_CAP & (IPC_RING_CAP - 1)) == 0,
               "IPC_RING_CAP must be a power of two");

/* ── Futex helpers ──────────────────────────────────────────────────── */

/*
 * Sleep until *addr != expected, or until woken by futex_wake_one().
 * EAGAIN means the value already changed – not an error.
 */
static void futex_wait_val(const _Atomic uint32_t *addr, uint32_t expected)
{
    syscall(SYS_futex,
            (volatile uint32_t *)addr,
            FUTEX_WAIT,
            (int)expected,
            NULL, NULL, 0);
}

/* Wake one thread sleeping in futex_wait_val() on *addr. */
static void futex_wake_one(const _Atomic uint32_t *addr)
{
    syscall(SYS_futex,
            (volatile uint32_t *)addr,
            FUTEX_WAKE,
            1, NULL, NULL, 0);
}

/* ── Shared-memory setup ────────────────────────────────────────────── */

static ShmChannel *shm_map_fd(int fd)
{
    size_t sz = sizeof(ShmChannel);
    void  *ptr = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        perror("ipc_transport: mmap");
        exit(1);
    }
    return (ShmChannel *)ptr;
}

ShmChannel *ipc_create(void)
{
    /* Remove a stale object from a previous run if present. */
    shm_unlink(IPC_SHM_NAME);

    int fd = shm_open(IPC_SHM_NAME, O_CREAT | O_RDWR, 0600);
    if (fd < 0) {
        perror("ipc_transport: shm_open (create)");
        exit(1);
    }
    if (ftruncate(fd, (off_t)sizeof(ShmChannel)) < 0) {
        perror("ipc_transport: ftruncate");
        exit(1);
    }

    ShmChannel *ch = shm_map_fd(fd);
    close(fd);

    /* The kernel zero-fills new shm pages, but be explicit. */
    memset(ch, 0, sizeof(ShmChannel));
    return ch;
}

ShmChannel *ipc_open(void)
{
    int fd = shm_open(IPC_SHM_NAME, O_RDWR, 0);
    if (fd < 0) {
        perror("ipc_transport: shm_open (open)");
        exit(1);
    }
    ShmChannel *ch = shm_map_fd(fd);
    close(fd);
    return ch;
}

/* ── SPSC ring-buffer operations ────────────────────────────────────── */

/*
 * Write exactly `len' bytes from `src' into `pipe'.
 *
 * The producer advances `tail' and wakes any reader sleeping on it.
 * If the buffer is full the producer sleeps on `head' (the futex word
 * the consumer wakes after freeing space).
 */
void shm_pipe_write(ShmPipe *pipe, const void *src, uint32_t len)
{
    const uint8_t *in        = (const uint8_t *)src;
    uint32_t       remaining = len;

    while (remaining > 0) {
        uint32_t tail = atomic_load_explicit(&pipe->tail, memory_order_relaxed);
        uint32_t head = atomic_load_explicit(&pipe->head, memory_order_acquire);

        /* Block while the buffer is full. */
        while ((tail - head) >= IPC_RING_CAP) {
            futex_wait_val(&pipe->head, head);
            head = atomic_load_explicit(&pipe->head, memory_order_acquire);
        }

        uint32_t space    = IPC_RING_CAP - (tail - head);
        uint32_t to_copy  = space < remaining ? space : remaining;
        uint32_t tail_idx = tail & (IPC_RING_CAP - 1u);
        uint32_t first    = IPC_RING_CAP - tail_idx;
        if (first > to_copy) first = to_copy;

        memcpy(pipe->buf + tail_idx, in, first);
        if (first < to_copy)
            memcpy(pipe->buf, in + first, to_copy - first);

        atomic_store_explicit(&pipe->tail, tail + to_copy, memory_order_release);
        futex_wake_one(&pipe->tail);   /* wake the reader */

        in        += to_copy;
        remaining -= to_copy;
    }
}

/*
 * Read exactly `len' bytes from `pipe' into `dst'.
 *
 * The consumer advances `head' and wakes any writer sleeping on it.
 * If the buffer is empty the consumer sleeps on `tail' (the futex word
 * the producer wakes after adding data).
 */
void shm_pipe_read(ShmPipe *pipe, void *dst, uint32_t len)
{
    uint8_t  *out      = (uint8_t *)dst;
    uint32_t  remaining = len;

    while (remaining > 0) {
        uint32_t head = atomic_load_explicit(&pipe->head, memory_order_relaxed);
        uint32_t tail = atomic_load_explicit(&pipe->tail, memory_order_acquire);

        /* Block while the buffer is empty. */
        while (tail == head) {
            futex_wait_val(&pipe->tail, tail);
            tail = atomic_load_explicit(&pipe->tail, memory_order_acquire);
        }

        uint32_t avail    = tail - head;
        uint32_t to_copy  = avail < remaining ? avail : remaining;
        uint32_t head_idx = head & (IPC_RING_CAP - 1u);
        uint32_t first    = IPC_RING_CAP - head_idx;
        if (first > to_copy) first = to_copy;

        memcpy(out, pipe->buf + head_idx, first);
        if (first < to_copy)
            memcpy(out + first, pipe->buf, to_copy - first);

        out       += to_copy;
        remaining -= to_copy;

        atomic_store_explicit(&pipe->head, head + to_copy, memory_order_release);
        futex_wake_one(&pipe->head);   /* wake the writer if blocked on full */
    }
}
