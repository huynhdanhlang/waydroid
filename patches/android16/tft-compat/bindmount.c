/* Android toybox mount treats /dev/null as a loop device. Use MS_BIND. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>

int main(int argc, char **argv)
{
    if (argc != 3 || strcmp(argv[1], "/dev/null") ||
        strncmp(argv[2], "/proc/", 6) ||
        !strstr(argv[2], "/task/") || !strstr(argv[2], "/syscall")) {
        fputs("usage: tft-bindmount /dev/null /proc/PID/task/TID/syscall\n", stderr);
        return 2;
    }
    if (mount(argv[1], argv[2], NULL, MS_BIND, NULL)) {
        fprintf(stderr, "bind mount failed: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}
