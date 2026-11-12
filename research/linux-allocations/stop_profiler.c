/* Disposable collector control: stop/flush heaptrack after confirmed Host drain,
 * before the existing fixture kills the Host. Never call it from a signal handler. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

static void *wait_for_stop(void *unused) {
    (void)unused;
    const char *fifo = getenv("RUI_HEAPTRACK_STOP_FIFO");
    int fd = open(fifo, O_RDWR | O_CLOEXEC);
    char command;
    if (fd < 0 || read(fd, &command, 1) != 1 || command != 's') _exit(91);
    void (*stop)(void) = dlsym(RTLD_DEFAULT, "heaptrack_stop");
    if (!stop) _exit(92);
    stop();
    int ack = open(getenv("RUI_HEAPTRACK_STOP_ACK"), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (ack < 0 || close(ack) || close(fd)) _exit(93);
    return NULL;
}

__attribute__((constructor)) static void start(void) {
    if (!getenv("RUI_HEAPTRACK_STOP_FIFO")) return;
    pthread_t thread;
    if (pthread_create(&thread, NULL, wait_for_stop, NULL) || pthread_detach(thread)) _exit(94);
}
