/*
 * Helper program to read data from a block device at an arbitrary offset
 * without using lseek(). Uses pread64() which is more reliable with BDUS devices.
 *
 * Usage: read_at_offset <device> <offset_bytes> <output_file> <size_bytes>
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUFFER_SIZE (1 * 1024 * 1024)  /* 1MB buffer */

int main(int argc, char *argv[])
{
    if (argc != 5) {
        fprintf(stderr, "Usage: %s <device> <offset_bytes> <output_file> <size_bytes>\n", argv[0]);
        fprintf(stderr, "  device:        Block device (e.g., /dev/bdus-0)\n");
        fprintf(stderr, "  offset_bytes:  Starting offset in bytes\n");
        fprintf(stderr, "  output_file:   File to write to\n");
        fprintf(stderr, "  size_bytes:    Number of bytes to read\n");
        return 1;
    }

    const char *device = argv[1];
    off64_t offset = strtoll(argv[2], NULL, 10);
    const char *output_file = argv[3];
    off64_t total_size = strtoll(argv[4], NULL, 10);

    /* Open device for reading */
    int dev_fd = open(device, O_RDONLY);
    if (dev_fd < 0) {
        perror("open(device)");
        return 1;
    }

    /* Open output file for writing */
    int out_fd = open(output_file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        perror("open(output_file)");
        close(dev_fd);
        return 1;
    }

    /* Read from device at specified offset and write to output file using pread64 */
    char buffer[BUFFER_SIZE];
    off64_t bytes_read = 0;

    while (bytes_read < total_size) {
        size_t to_read = (total_size - bytes_read > BUFFER_SIZE) 
                        ? BUFFER_SIZE 
                        : (size_t)(total_size - bytes_read);
        
        /* Use pread64 to read at the specified offset without seeking */
        ssize_t n_read = pread64(dev_fd, buffer, to_read, offset + bytes_read);
        if (n_read < 0) {
            perror("pread64(device)");
            close(dev_fd);
            close(out_fd);
            return 1;
        }
        if (n_read == 0) {
            fprintf(stderr, "pread64: unexpected EOF\n");
            break;
        }

        ssize_t n_written = write(out_fd, buffer, (size_t)n_read);
        if (n_written < 0) {
            perror("write(output_file)");
            close(dev_fd);
            close(out_fd);
            return 1;
        }
        if (n_written != n_read) {
            fprintf(stderr, "write: partial write (%zd != %zd)\n", n_written, n_read);
            close(dev_fd);
            close(out_fd);
            return 1;
        }

        bytes_read += n_read;
    }

    close(dev_fd);
    close(out_fd);

    return 0;
}
