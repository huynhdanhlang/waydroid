#!/usr/bin/env bash
# Run the low-address JIT regression against the translator in the guest.
set -euo pipefail

if (( EUID != 0 )); then
    echo 'Run as root against a running Waydroid container.' >&2
    exit 1
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
container_pid=$(lxc-info -P /var/lib/waydroid/lxc -n waydroid -p -H)
if [[ ! $container_pid =~ ^[0-9]+$ ]]; then
    echo 'Waydroid container is not running.' >&2
    exit 1
fi
runtime_libs=/proc/$container_pid/root/apex/com.android.runtime/lib64/bionic
system_libs=/proc/$container_pid/root/system/lib64
guest_binary=/proc/$container_pid/root/data/local/tmp/tft-berberis-mmap-test
build_dir=$(mktemp -d)
trap 'rm -f -- "$guest_binary"; rm -rf -- "$build_dir"' EXIT

clang --target=x86_64-linux-android35 -fuse-ld=lld -fPIE -pie -nostdlib \
    -Wall -Wextra -Werror -Wl,-dynamic-linker,/system/bin/linker64 \
    -Wl,-e,_start -Wl,--no-undefined \
    -L "$runtime_libs" -L "$system_libs" \
    "$here/test_berberis_mmap.c" -o "$build_dir/probe" -lndk_translation -lc
install -m 755 "$build_dir/probe" "$guest_binary"
waydroid shell -- /data/local/tmp/tft-berberis-mmap-test |
    grep -q 'two low JIT mappings succeeded'
echo 'Berberis mapped two 4 MiB executable regions below 1 GiB.'
