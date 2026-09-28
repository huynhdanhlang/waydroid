/* Host service: resume only a stopped TFT process after masking its proc probe. */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static void stop(int unused) { (void)unused; running = 0; }

static int target_pid(int pid, int *guest_pid)
{
    char path[64], text[512];
    snprintf(path, sizeof path, "/proc/%d/comm", pid);
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    int match = fgets(text, sizeof text, file) &&
                (strcmp(text, "eamfighttactics\n") == 0 ||
                 strcmp(text, "mfighttacticsvn\n") == 0);
    fclose(file);
    if (!match) return 0;

    snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
    file = fopen(path, "r");
    if (!file) return 0;
    match = fgets(text, sizeof text, file) &&
            (strcmp(text, "com.riotgames.league.teamfighttactics") == 0 ||
             strcmp(text, "com.riotgames.league.teamfighttacticsvn") == 0);
    fclose(file);
    if (!match) return 0;

    snprintf(path, sizeof path, "/proc/%d/status", pid);
    file = fopen(path, "r");
    if (!file) return 0;
    int stopped = 0, guest = 0, uid = 0;
    while (fgets(text, sizeof text, file)) {
        if (strncmp(text, "State:", 6) == 0) {
            char state = 0;
            sscanf(text + 6, " %c", &state);
            stopped = state == 'T';
        } else if (strncmp(text, "NSpid:", 6) == 0) {
            int host = 0;
            if (sscanf(text + 6, "%d %d", &host, &guest) != 2 || host != pid)
                guest = 0;
        } else if (strncmp(text, "Uid:", 4) == 0) {
            sscanf(text + 4, "%d", &uid);
        }
    }
    fclose(file);
    if (!stopped || guest < 1 || uid < 10000 || uid >= 20000) return 0;
    *guest_pid = guest;
    return 1;
}

static void mask_and_resume(int host, int guest)
{
    char host_text[32], path[96];
    snprintf(host_text, sizeof host_text, "%d", host);
    snprintf(path, sizeof path, "/proc/%d/task/%d/syscall", guest, guest);
    pid_t child = fork();
    if (child == 0) {
        execl("/usr/bin/nsenter", "nsenter", "-t", host_text, "-m", "-p",
              "--", "/system/bin/tft-bindmount", "/dev/null", path,
              (char *)NULL);
        _exit(127);
    }
    int status = -1;
    if (child > 0) {
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    fprintf(stderr, "TFT host=%d guest=%d mask=%s\n", host, guest,
            ok ? "ok" : "failed");
    if (kill(host, SIGCONT))
        fprintf(stderr, "SIGCONT %d failed: %s\n", host, strerror(errno));
}

int main(void)
{
    if (geteuid() != 0) {
        fputs("tft-mask-watcher requires root\n", stderr);
        return 1;
    }
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 250000000 };
    while (running) {
        DIR *dir = opendir("/proc");
        if (!dir) return 1;
        struct dirent *entry;
        while ((entry = readdir(dir))) {
            if (!isdigit((unsigned char)entry->d_name[0])) continue;
            int pid = atoi(entry->d_name), guest = 0;
            if (target_pid(pid, &guest)) mask_and_resume(pid, guest);
        }
        closedir(dir);
        nanosleep(&delay, NULL);
    }
    return 0;
}
