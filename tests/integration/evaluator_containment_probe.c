#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    unsigned env_count = 0, extra_fds = 0;
    while (environ[env_count]) env_count++;
    /* Inspection only: the production parent does not scan the descriptor
     * limit, and this fixture never becomes the author-code process. */
    for (int fd = 3; fd < 256; fd++)
        if (fcntl(fd, F_GETFD) != -1) extra_fds++;
    if (argc != 2 || env_count != 0) return 2;
    if (!strcmp(argv[1], "check-prepared")) return extra_fds == 1 ? 0 : 2;
    if (strcmp(argv[1], "run-prepared") || extra_fds != 2) return 2;
    char text[80];
    int size = snprintf(text, sizeof(text), "{\"env\":%u,\"extraFds\":%u}",
                        env_count, extra_fds);
    unsigned char header[4] = {0}, end[4] = {0};
    header[0] = (unsigned char)size;
    return write(1, header, 4) == 4 && write(1, text, (size_t)size) == size &&
           write(1, end, 4) == 4 ? 0 : 1;
}
