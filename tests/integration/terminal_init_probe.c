/* Deliver input after real raw installation, or inject only the subsequent
 * restoration failure. TCSAFLUSH discards input queued before installation. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static int raw_seen;

int tcsetattr(int fd, int action, const struct termios *mode) {
    int (*real_set)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    const char *notice = getenv("RUI_INIT_RESTORE_NOTICE_FD");
    if (fd == 0 && raw_seen && (mode->c_lflag & ICANON) && notice) {
        if (write(atoi(notice), "R", 1) != 1) _exit(92);
        errno = EIO;
        return -1;
    }
    int result = real_set(fd, action, mode);
    int saved_errno = errno;
    const char *master = getenv("RUI_INIT_MASTER_FD");
    const char *input = getenv("RUI_INIT_INPUT");
    if (result == 0 && fd == 0 && !(mode->c_lflag & ICANON)) raw_seen = 1;
    if (result == 0 && fd == 0 && !(mode->c_lflag & ICANON) && master && input) {
        size_t length = strlen(input);
        if (write(atoi(master), input, length) != (ssize_t)length) _exit(91);
    }
    errno = saved_errno;
    return result;
}
