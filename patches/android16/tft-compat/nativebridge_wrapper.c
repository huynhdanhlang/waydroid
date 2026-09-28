/* Android 16 NativeBridge v8 wrapper for TFT's early mVG probe.
 *
 * The host watcher bind-mounts /dev/null over this process's proc syscall
 * file while stopped. This affects only the TFT process and no game files.
 */
#include <signal.h>
#include <stddef.h>
#include <stdint.h>

extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int __android_log_print(int, const char *, const char *, ...);
extern char *strstr(const char *, const char *);

struct bridge_callbacks {
    uint32_t version;
    uint32_t padding;
    void *slot[20];
};
_Static_assert(sizeof(struct bridge_callbacks) == 168, "NativeBridge v8 ABI");

__attribute__((visibility("default"))) struct bridge_callbacks NativeBridgeItf;
static void *(*original_load_ext)(const char *, int, void *);
static int paused;

static void *load_ext(const char *path, int flags, void *ns)
{
    if (path && strstr(path, "com.riotgames.league.teamfighttactics") &&
        strstr(path, "/libmvg.so") && !paused) {
        paused = 1;
        __android_log_print(4, "tft-waydroid-bridge", "pausing before %s", path);
        raise(SIGSTOP);
        __android_log_print(4, "tft-waydroid-bridge", "resuming %s", path);
    }
    return original_load_ext(path, flags, ns);
}

__attribute__((constructor)) static void setup(void)
{
    void *handle = dlopen("libndk_translation.so", 1);
    if (!handle) {
        __android_log_print(6, "tft-waydroid-bridge", "translator not found");
        return;
    }
    struct bridge_callbacks *original = dlsym(handle, "NativeBridgeItf");
    if (!original || original->version != 8 || !original->slot[13]) {
        __android_log_print(6, "tft-waydroid-bridge", "unsupported NativeBridge ABI");
        return;
    }
    unsigned char *dest = (unsigned char *)&NativeBridgeItf;
    const unsigned char *src = (const unsigned char *)original;
    for (size_t i = 0; i < sizeof NativeBridgeItf; ++i)
        dest[i] = src[i];
    original_load_ext = (void *(*)(const char *, int, void *))NativeBridgeItf.slot[13];
    NativeBridgeItf.slot[13] = (void *)load_ext;
    __android_log_print(4, "tft-waydroid-bridge", "v8 wrapper installed");
}
