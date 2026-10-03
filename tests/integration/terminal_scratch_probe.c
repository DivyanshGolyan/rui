/* Observe regular-file growth through production writes, without imposing a
 * product quota. The notice pipe contains fixed-size off_t measurements. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

static void observe(int fd) {
    struct stat status;
    const char *notice = getenv("RUI_SCRATCH_NOTICE_FD");
    if (notice && fstat(fd, &status) == 0 && S_ISREG(status.st_mode)) {
        ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
        if (real_write(atoi(notice), &status.st_size, sizeof(status.st_size)) != sizeof(status.st_size)) _exit(97);
    }
}

ssize_t write(int fd, const void *bytes, size_t length) {
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    ssize_t result = real_write(fd, bytes, length);
    int saved = errno;
    if (result > 0) observe(fd);
    errno = saved;
    return result;
}

ssize_t writev(int fd, const struct iovec *vectors, int count) {
    ssize_t (*real_write)(int, const struct iovec *, int) = dlsym(RTLD_NEXT, "writev");
    ssize_t result = real_write(fd, vectors, count);
    int saved = errno;
    if (result > 0) observe(fd);
    errno = saved;
    return result;
}

ssize_t pwritev64(int fd, const struct iovec *vectors, int count, off64_t offset) {
    ssize_t (*real_write)(int, const struct iovec *, int, off64_t) = dlsym(RTLD_NEXT, "pwritev64");
    ssize_t result = real_write(fd, vectors, count, offset);
    int saved = errno;
    if (result > 0) observe(fd);
    errno = saved;
    return result;
}

ssize_t pwrite64(int fd, const void *bytes, size_t length, off64_t offset) {
    ssize_t (*real_write)(int, const void *, size_t, off64_t) = dlsym(RTLD_NEXT, "pwrite64");
    ssize_t result = real_write(fd, bytes, length, offset);
    int saved = errno;
    if (result > 0) observe(fd);
    errno = saved;
    return result;
}
