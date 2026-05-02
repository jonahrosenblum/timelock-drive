#pragma once

/*
 * Shared-memory IPC transport for timelocked-storage.
 *
 * Two processes (the Rust gatekeeper server and the C versioning driver)
 * communicate over a POSIX shared-memory region containing two SPSC
 * (single-producer, single-consumer) ring buffers:
 *
 *   c2s  –  client → server  (driver writes, gatekeeper reads)
 *   s2c  –  server → client  (gatekeeper writes, driver reads)
 *
 * The ring-buffer layout MUST exactly match the Rust ShmPipe / ShmChannel
 * structs in gatekeeper/rust-externs/externs.rs.
 *
 * Synchronisation uses Linux futex(2).  Readers sleep on &pipe->tail;
 * writers sleep on &pipe->head when the buffer is full.
 * IPC_RING_CAP must be a power of two.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>

/* POSIX shared-memory object name (created under /dev/shm/). */
#define IPC_SHM_NAME  "/timelocked_ipc"

/* Capacity of each ring buffer in bytes.  4 MiB – large enough to
 * absorb the longest single message in either direction without
 * blocking.  Must be a power of two. */
#define IPC_RING_CAP  (4u * 1024u * 1024u)

/*
 * One-directional SPSC ring buffer.
 *
 * head  – consumer's read position (also futex word: woken when head advances)
 * tail  – producer's write position (also futex word: woken when tail advances)
 * _pad  – padding so that head+tail occupy exactly one 64-byte cache line
 * buf   – circular data buffer
 */
typedef struct __attribute__((aligned(64))) {
    _Atomic uint32_t head;      /* consumer advances; futex word for "space available" */
    _Atomic uint32_t tail;      /* producer advances; futex word for "data available"  */
    uint32_t         _pad[14];  /* pad header to 64 bytes                              */
    uint8_t          buf[IPC_RING_CAP];
} ShmPipe;

/* Full-duplex channel: two independent SPSC pipes. */
typedef struct {
    ShmPipe c2s;   /* client → server */
    ShmPipe s2c;   /* server → client */
} ShmChannel;

/*
 * Server: create (or replace) the shared-memory object, initialise it,
 * and return a pointer to the mapped channel.  Call once at startup.
 */
ShmChannel *ipc_create(void);

/*
 * Client: open an existing shared-memory object created by the server
 * and return a pointer to the mapped channel.  The server must have
 * called ipc_create() before this is called.
 */
ShmChannel *ipc_open(void);

/*
 * Write exactly `len' bytes from `src' into `pipe'.
 * Blocks (via futex) if the ring buffer is full.
 */
void shm_pipe_write(ShmPipe *pipe, const void *src, uint32_t len);

/*
 * Read exactly `len' bytes from `pipe' into `dst'.
 * Blocks (via futex) if the ring buffer is empty.
 */
void shm_pipe_read(ShmPipe *pipe, void *dst, uint32_t len);
