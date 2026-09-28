/* Host regression test for a touchscreen FIFO replaced after a display resize.
 * Build pointer_touch.c with open/readlink redirected to the path adapters
 * below; the shim's real write() implementation remains under test.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char touch_path[] = "/tmp/tft-pointer-test-XXXXXX/touch";
static int pointer_fd;

int __system_property_get(const char *name, char *value)
{
    if (strcmp(name, "waydroid.active_apps")) return 0;
    strcpy(value, "com.riotgames.league.teamfighttacticsvn");
    return 39;
}

int __android_log_print(int priority, const char *tag, const char *format, ...)
{
    (void)priority;
    (void)tag;
    (void)format;
    return 0;
}

int test_open(const char *path, int flags, ...)
{
    if (!strcmp(path, "/dev/input/wl_touch_events")) path = touch_path;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode_t mode = va_arg(args, int);
        va_end(args);
        return open(path, flags, mode);
    }
    return open(path, flags);
}

ssize_t test_readlink(const char *path, char *buffer, size_t size)
{
    char pointer_path[64];
    snprintf(pointer_path, sizeof pointer_path, "/proc/self/fd/%d", pointer_fd);
    if (!strcmp(path, pointer_path)) {
        const char target[] = "/dev/input/wl_pointer_events";
        if (size < sizeof target - 1) return -1;
        memcpy(buffer, target, sizeof target - 1);
        return sizeof target - 1;
    }
    return readlink(path, buffer, size);
}

static void fail(const char *message)
{
    perror(message);
    exit(1);
}

static void send_event(unsigned short type, unsigned short code, int value)
{
    struct input_event events[2] = {0};
    events[0].type = type;
    events[0].code = code;
    events[0].value = value;
    events[1].type = EV_SYN;
    events[1].code = SYN_REPORT;
    if (write(pointer_fd, events, sizeof events) != sizeof events)
        fail("pointer write");
}

static void send_motion(int x, int y)
{
    struct input_event events[5] = {0};
    events[0].type = EV_ABS;
    events[0].code = ABS_X;
    events[0].value = x;
    events[1].type = EV_ABS;
    events[1].code = ABS_Y;
    events[1].value = y;
    events[2].type = EV_REL;
    events[2].code = REL_X;
    events[3].type = EV_REL;
    events[3].code = REL_Y;
    events[4].type = EV_SYN;
    if (write(pointer_fd, events, sizeof events) != sizeof events)
        fail("pointer motion write");
}

static void check_touch(int reader, int down, int expected_x, int expected_y)
{
    struct input_event events[6];
    size_t expected = down ? 6 : 3;
    for (size_t i = 0; i < expected; ++i) {
        if (read(reader, &events[i], sizeof events[i]) != sizeof events[i])
            fail("read touch packet");
    }
    if (events[0].type != EV_ABS ||
        events[0].code != ABS_MT_SLOT ||
        events[1].code != ABS_MT_TRACKING_ID ||
        events[1].value != (down ? 9 : -1) ||
        events[expected - 1].type != EV_SYN) {
        fprintf(stderr, "touch packet mismatch: expected %zu events\n", expected);
        exit(1);
    }
    if (down && (events[2].code != ABS_MT_POSITION_X || events[2].value != expected_x ||
                 events[3].code != ABS_MT_POSITION_Y || events[3].value != expected_y)) {
        fprintf(stderr, "touch coordinates mismatch\n");
        exit(1);
    }
}

int main(void)
{
    char directory[] = "/tmp/tft-pointer-test-XXXXXX";
    if (!mkdtemp(directory)) fail("mkdtemp");
    snprintf(touch_path, sizeof touch_path, "%s/touch", directory);
    if (mkfifo(touch_path, 0600)) fail("mkfifo touch");
    int reader = open(touch_path, O_RDONLY | O_NONBLOCK);
    if (reader < 0) fail("open touch reader");
    pointer_fd = open("/dev/null", O_WRONLY);
    if (pointer_fd < 0) fail("open pointer");

    send_motion(1920, 1400);
    send_event(EV_KEY, BTN_LEFT, 1);
    check_touch(reader, 1, 1920, 1400);
    send_motion(2050, 1510);
    check_touch(reader, 1, 2050, 1510);
    /* A surface switch may swallow BTN_LEFT up. The next press must clear
     * the stale tracking ID before starting a new gesture. */
    send_event(EV_KEY, BTN_LEFT, 1);
    check_touch(reader, 0, 0, 0);
    check_touch(reader, 1, 2050, 1510);
    send_event(EV_KEY, BTN_LEFT, 0);
    check_touch(reader, 0, 0, 0);

    /* HWC's reset_input_pipe() removes the old FIFO on display resize. */
    close(reader);
    if (unlink(touch_path) || mkfifo(touch_path, 0600)) fail("rotate touch FIFO");
    reader = open(touch_path, O_RDONLY | O_NONBLOCK);
    if (reader < 0) fail("reopen touch reader");
    send_event(EV_KEY, BTN_LEFT, 1);
    check_touch(reader, 1, 2050, 1510);
    send_event(EV_KEY, BTN_LEFT, 0);
    check_touch(reader, 0, 0, 0);

    close(reader);
    close(pointer_fd);
    unlink(touch_path);
    rmdir(directory);
    puts("pointer touch supports drag and FIFO replacement");
    return 0;
}
