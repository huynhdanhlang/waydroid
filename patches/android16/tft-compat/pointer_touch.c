/* Convert only TFT's Wayland left-clicks to Android touchscreen events.
 * Preload this into Waydroid's hwcomposer service, not into the game.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* The installer uses host headers with an Android linker and Bionic libc. */
#ifdef __ANDROID__
extern int *__errno(void);
#undef errno
#define errno (*__errno())
#endif

extern int __system_property_get(const char *, char *);
extern int __android_log_print(int, const char *, const char *, ...);

static ssize_t (*system_write)(int, const void *, size_t);
static int pointer_fd = -1;
static int x, y, have_position, touch_down;

static void add_event(struct input_event *event, int type, int code, int value)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    event->time.tv_sec = now.tv_sec;
    event->time.tv_usec = now.tv_nsec / 1000;
    event->type = type;
    event->code = code;
    event->value = value;
}

static int active_tft(void)
{
    char package[128] = {0};
    if (__system_property_get("waydroid.active_apps", package) <= 0)
        return 0;
    return strcmp(package, "com.riotgames.league.teamfighttactics") == 0 ||
           strcmp(package, "com.riotgames.league.teamfighttacticsvn") == 0 ||
           strcmp(package, "Waydroid") == 0;
}

enum touch_phase { TOUCH_DOWN, TOUCH_MOVE, TOUCH_UP };

static int send_touch(enum touch_phase phase)
{
    /* HWC unlinks and recreates this FIFO during display hotplug. Never keep
     * an fd across packets: it can point at a FIFO with no reader afterward. */
    int touch_fd = open("/dev/input/wl_touch_events", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (touch_fd < 0) return 0;

    struct input_event events[6];
    size_t n = 0;
    add_event(&events[n++], EV_ABS, ABS_MT_SLOT, 9);
    add_event(&events[n++], EV_ABS, ABS_MT_TRACKING_ID,
              phase == TOUCH_UP ? -1 : 9);
    if (phase != TOUCH_UP) {
        add_event(&events[n++], EV_ABS, ABS_MT_POSITION_X, x);
        add_event(&events[n++], EV_ABS, ABS_MT_POSITION_Y, y);
        add_event(&events[n++], EV_ABS, ABS_MT_PRESSURE, 50);
    }
    add_event(&events[n++], EV_SYN, SYN_REPORT, 0);
    /* A resize can still remove the FIFO between open() and write(). Block
     * SIGPIPE in this thread and consume only the signal this write creates. */
    sigset_t pipe_signal, old_mask, pending;
    sigemptyset(&pipe_signal);
    sigaddset(&pipe_signal, SIGPIPE);
    int masked = pthread_sigmask(SIG_BLOCK, &pipe_signal, &old_mask) == 0;
    int already_pending = masked && sigpending(&pending) == 0 &&
                          sigismember(&pending, SIGPIPE);
    ssize_t result = system_write(touch_fd, events, n * sizeof events[0]);
    int write_error = errno;
    if (masked) {
        if (result < 0 && write_error == EPIPE && !already_pending) {
            struct timespec zero = {0, 0};
            sigtimedwait(&pipe_signal, NULL, &zero);
        }
        pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
    }
    close(touch_fd);
    if (result == (ssize_t)(n * sizeof events[0])) return 1;
    __android_log_print(6, "tft-pointer-touch",
                        "touch FIFO write failed: result=%zd errno=%d", result, write_error);
    return 0;
}

__attribute__((constructor)) static void init(void)
{
    system_write = dlsym(RTLD_NEXT, "write");
}

ssize_t write(int fd, const void *buffer, size_t count)
{
    if (!system_write) system_write = dlsym(RTLD_NEXT, "write");
    if (!system_write) return -1;

    if (pointer_fd < 0) {
        char fdpath[64], target[128];
        snprintf(fdpath, sizeof fdpath, "/proc/self/fd/%d", fd);
        ssize_t size = readlink(fdpath, target, sizeof target - 1);
        if (size > 0) {
            target[size] = '\0';
            if (strcmp(target, "/dev/input/wl_pointer_events") == 0)
                pointer_fd = fd;
        }
    }
    if (fd != pointer_fd || count % sizeof(struct input_event))
        return system_write(fd, buffer, count);

    const struct input_event *event = buffer;
    int button = -1;
    int moved = 0;
    for (size_t i = 0; i < count / sizeof(*event); ++i) {
        if (event[i].type == EV_ABS && event[i].code == ABS_X) {
            moved |= x != event[i].value;
            x = event[i].value;
            have_position = 1;
        } else if (event[i].type == EV_ABS && event[i].code == ABS_Y) {
            moved |= y != event[i].value;
            y = event[i].value;
        } else if (event[i].type == EV_KEY && event[i].code == BTN_LEFT) {
            button = event[i].value;
        }
    }

    if (button >= 0 && have_position && (touch_down || active_tft())) {
        if (button) {
            if (touch_down) {
                /* A Wayland surface switch can lose the release event. */
                __android_log_print(5, "tft-pointer-touch",
                                    "recovering missing left-button release");
                send_touch(TOUCH_UP);
                touch_down = 0;
            }
            if (send_touch(TOUCH_DOWN)) {
                touch_down = 1;
                return count;
            }
        }
        if (!button && touch_down) {
            int sent = send_touch(TOUCH_UP);
            touch_down = 0;
            if (sent) return count;
        }
    }
    if (button < 0 && moved && touch_down && send_touch(TOUCH_MOVE))
        return count;
    return system_write(fd, buffer, count);
}
