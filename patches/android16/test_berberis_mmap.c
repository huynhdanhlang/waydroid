/* Android x86_64 integration probe for Berberis's low-address JIT mapping.
 * An executable memfd must still map below 2 GiB after the 1-2 GiB range is
 * occupied. On the unpatched July translator, MmapImplOrDie aborts instead.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

struct mmap_args {
    void *address;
    size_t length;
    int protection;
    int flags;
    int fd;
    int padding;
    off_t offset;
    unsigned char low_32_bits;
    unsigned char tail[7];
};
_Static_assert(sizeof(struct mmap_args) == 48, "Berberis mmap ABI");
extern void *berberis_mmap_or_die(struct mmap_args)
    __asm__("_ZN8berberis13MmapImplOrDieENS_12MmapImplArgsE");

static void fail(const char *message, int code)
{
    const char *end = message;
    while (*end) ++end;
    write(2, message, end - message);
    _exit(code);
}

__attribute__((noreturn)) void _start(void)
{
    const size_t length = 4UL << 20;
    for (uintptr_t at = 0x40000000UL; at + length <= 0x80000000UL;
         at += length) {
        /* Existing Bionic/translator mappings can occupy individual slots.
         * Leave those intact and reserve each available 4 MiB slot. */
        mmap((void *)at, length, PROT_NONE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    }

    int fd = syscall(SYS_memfd_create, "tft-berberis-probe", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, length)) fail("cannot prepare exec memfd\n", 2);
    struct mmap_args args = {
        .address = 0,
        .length = length,
        .protection = PROT_READ | PROT_EXEC,
        .flags = MAP_SHARED,
        .fd = fd,
        .offset = 0,
        .low_32_bits = 1,
    };
    void *first = berberis_mmap_or_die(args);
    void *second = berberis_mmap_or_die(args);
    if (first == MAP_FAILED || second == MAP_FAILED || first == second ||
        (uintptr_t)first >= 0x40000000UL ||
        (uintptr_t)second >= 0x40000000UL)
        fail("invalid low mapping\n", 1);

    munmap(first, length);
    munmap(second, length);
    close(fd);
    write(1, "two low JIT mappings succeeded\n", 31);
    _exit(0);
}
