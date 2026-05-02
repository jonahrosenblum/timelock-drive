/*
 * Helper program to write data to a block device at an arbitrary offset
 * without using lseek(). Uses pwrite64() which is more reliable with BDUS devices.
 *
 * Usage: write_at_offset <device> <offset_bytes> <input_file>
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#define BUFFER_SIZE (1 * 1024 * 1024)  /* 1MB buffer */

int main(int argc, char *argv[])
{
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <device> <offset_bytes> <input_file>\n", argv[0]);
        fprintf(stderr, "  device:        Block device (e.g., /dev/bdus-0)\n");
        fprintf(stderr, "  offset_bytes:  Starting offset in bytes\n");
        fprintf(stderr, "  input_file:    File to write from\n");
        return 1;
    }

    const char *device = argv[1];
    off64_t offset = strtoll(argv[2], NULL, 10);
    const char *input_file = argv[3];

    /* Open input file for reading */
    int src_fd = open(input_file, O_RDONLY);
    if (src_fd < 0) {
        perror("open(input_file)");
        return 1;
    }

    /* Get input file size */
    struct stat sb;
    if (fstat(src_fd, &sb) < 0) {
        perror("fstat(input_file)");
        close(src_fd);
        return 1;
    }
    off64_t file_size = sb.st_size;

    /* Open device for writing */
    int dev_fd = open(device, O_WRONLY);
    if (dev_fd < 0) {
        perror("open(device)");
        close(src_fd);
        return 1;
    }

    /* Write file data to device at specified offset using pwrite64 */
    char buffer[BUFFER_SIZE];
    off64_t bytes_written = 0;

    while (bytes_written < file_size) {
        size_t to_read = (file_size - bytes_written > BUFFER_SIZE) 
                        ? BUFFER_SIZE 
                        : (size_t)(file_size - bytes_written);
        
        ssize_t n_read = read(src_fd, buffer, to_read);
        if (n_read < 0) {
            perror("read(input_file)");
            close(src_fd);
            close(dev_fd);
            return 1;
        }
        if (n_read == 0) break;

        /* Use pwrite64 to write at the specified offset without seeking */
        ssize_t n_written = pwrite64(dev_fd, buffer, (size_t)n_read, offset + bytes_written);
        if (n_written < 0) {
            perror("pwrite64(device)");
            close(src_fd);
            close(dev_fd);
            return 1;
        }
        if (n_written != n_read) {
            fprintf(stderr, "pwrite64: partial write (%zd != %zd)\n", n_written, n_read);
            close(src_fd);
            close(dev_fd);
            return 1;
        }

        bytes_written += n_written;
    }

    close(src_fd);
    close(dev_fd);

    return 0;
}
