#!/usr/bin/env bash
# Install the verified Android 16 compatibility files from this checkout.
set -euo pipefail

if (( EUID != 0 )); then
    echo 'Run install.sh as root.' >&2
    exit 1
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
image_dir=${WAYDROID_IMAGE_DIR:-/etc/waydroid-extra/images}
base_prop=/var/lib/waydroid/waydroid_base.prop
net_script=/usr/lib/waydroid/data/scripts/waydroid-net.sh
hardware_manager=/usr/lib/waydroid/tools/services/hardware_manager.py
user_manager=/usr/lib/waydroid/tools/services/user_manager.py
container_manager=/usr/lib/waydroid/tools/actions/container_manager.py
images_helper=/usr/lib/waydroid/tools/helpers/images.py
lxc_helper=/usr/lib/waydroid/tools/helpers/lxc.py
waydroid_config=/var/lib/waydroid/waydroid.cfg
init_rc=/var/lib/waydroid/rootfs/system/etc/init/init.waydroid.rc
vendor_image=$image_dir/vendor.img
system_image=$image_dir/system.img
container_pid=$(lxc-info -P /var/lib/waydroid/lxc -n waydroid -p -H)

for tool in clang cc debugfs lxc-info mount mountpoint nsenter python3 systemctl umount; do
    command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
if [[ ! $container_pid =~ ^[0-9]+$ || ! -d /proc/$container_pid/root ]]; then
    echo 'Start the Android 16 Waydroid container before installing.' >&2
    exit 1
fi
[[ -f $vendor_image && -f $system_image && -f $base_prop && -f $net_script &&
   -f $hardware_manager && -f $user_manager && -f $container_manager &&
   -f $images_helper && -f $lxc_helper && -f $waydroid_config && -f $init_rc ]] || {
    echo 'Expected Waydroid image/config/network files are absent.' >&2
    exit 1
}
if [[ $(grep -c '^suspend_action[[:space:]]*=' "$waydroid_config") != 1 ]]; then
    echo 'Expected exactly one suspend_action setting.' >&2
    exit 1
fi
if grep -q '^ro.dalvik.vm.native.bridge=' "$base_prop"; then
    grep -qx 'ro.dalvik.vm.native.bridge=libtftbridgeprobe.so' "$base_prop" || {
        echo 'Conflicting NativeBridge setting in waydroid_base.prop' >&2; exit 1;
    }
fi
if grep -q '^berberis.mode=' "$base_prop"; then
    grep -Eqx 'berberis.mode=(lite-translate-or-interpret|interpret-only)' "$base_prop" || {
        echo 'Conflicting Berberis mode in waydroid_base.prop' >&2; exit 1;
    }
fi

build_dir=$(mktemp -d)
system_mount=$(mktemp -d)
cleanup() {
    if mountpoint -q "$system_mount"; then
        umount "$system_mount" || {
            echo "Could not unmount $system_mount" >&2
            return 1
        }
    fi
    rmdir "$system_mount"
    rm -rf -- "$build_dir"
}
trap cleanup EXIT
debugfs -R "dump /lib64/hw/hwcomposer.waydroid.so $build_dir/hwcomposer-original.so" \
    "$vendor_image" >/dev/null 2>&1
python3 "$here/../patch_hwcomposer_prebuilt.py" \
    "$build_dir/hwcomposer-original.so" "$build_dir/hwcomposer-patched.so"
mount -t erofs -o ro,loop "$system_image" "$system_mount"
python3 "$here/../patch_berberis_prebuilt.py" \
    "$system_mount/system/lib64/libndk_translation.so" "$build_dir/berberis-patched.so"
umount "$system_mount"
python3 "$here/patch_init_rc.py" "$init_rc" "$build_dir/init.waydroid.rc"

runtime_libs=/proc/$container_pid/root/apex/com.android.runtime/lib64/bionic
system_libs=/proc/$container_pid/root/system/lib64
for lib in "$runtime_libs/libc.so" "$runtime_libs/libdl.so" "$system_libs/liblog.so"; do
    [[ -f $lib ]] || { echo "Missing Android library: $lib" >&2; exit 1; }
done
clang --target=x86_64-linux-android35 -fuse-ld=lld -shared -fPIC -nostdlib \
    -Wl,-soname,libtftbridgeprobe.so -Wl,--no-undefined \
    -L "$runtime_libs" -L "$system_libs" \
    "$here/nativebridge_wrapper.c" -o "$build_dir/libtftbridgeprobe.so" \
    -ldl -lc -llog
clang --target=x86_64-linux-android35 -fuse-ld=lld -shared -fPIC -nostdlib \
    -Wall -Wextra -Werror -Wl,-soname,libtftpointer.so -Wl,--no-undefined \
    -L "$runtime_libs" -L "$system_libs" \
    "$here/pointer_touch.c" -o "$build_dir/libtftpointer.so" \
    -ldl -lc -llog
cc -Wall -Wextra -Werror -O2 -static \
    "$here/bindmount.c" -o "$build_dir/tft-bindmount"
cc -Wall -Wextra -Werror -O2 \
    "$here/mask_watcher.c" -o "$build_dir/tft-waydroid-mask-watcher"

# All checks/builds precede installation. Overlay files take effect on the
# next container start; no game binary or downloaded game data is modified.
install -D -o root -g root -m 644 "$build_dir/hwcomposer-patched.so" \
    /var/lib/waydroid/overlay/vendor/lib64/hw/hwcomposer.waydroid.so
install -D -o root -g root -m 644 "$build_dir/libtftbridgeprobe.so" \
    /var/lib/waydroid/overlay/system/lib64/libtftbridgeprobe.so
install -D -o root -g root -m 644 "$build_dir/berberis-patched.so" \
    /var/lib/waydroid/overlay/system/lib64/libndk_translation.so
install -D -o root -g root -m 644 "$build_dir/libtftpointer.so" \
    /var/lib/waydroid/overlay/vendor/lib64/libtftpointer.so
install -D -o root -g root -m 644 "$build_dir/init.waydroid.rc" \
    /var/lib/waydroid/overlay/system/etc/init/init.waydroid.rc
install -D -o root -g root -m 755 "$build_dir/tft-bindmount" \
    /var/lib/waydroid/overlay/system/bin/tft-bindmount
install -D -o root -g root -m 755 "$build_dir/tft-waydroid-mask-watcher" \
    /usr/local/libexec/tft-waydroid-mask-watcher
install -D -o root -g root -m 755 "$here/launch-tft.sh" \
    /usr/local/bin/tft-waydroid
install -D -o root -g root -m 644 "$here/tft-waydroid-mask.service" \
    /etc/systemd/system/tft-waydroid-mask.service

if grep -q '^ro.dalvik.vm.native.bridge=' "$base_prop"; then
    :
else
    printf '\nro.dalvik.vm.native.bridge=libtftbridgeprobe.so\n' >>"$base_prop"
fi
if grep -q '^berberis.mode=' "$base_prop"; then
    sed -i 's/^berberis.mode=interpret-only$/berberis.mode=lite-translate-or-interpret/' \
        "$base_prop"
else
    printf 'berberis.mode=lite-translate-or-interpret\n' >>"$base_prop"
fi
echo 'Berberis lite translation selected with the verified low-address JIT mmap retry.'

install -D -o root -g root -m 755 "$here/../../../data/scripts/waydroid-net.sh" \
    "$net_script"
install -D -o root -g root -m 644 "$here/../../../tools/services/hardware_manager.py" \
    "$hardware_manager"
install -D -o root -g root -m 644 "$here/../../../tools/services/user_manager.py" \
    "$user_manager"
install -D -o root -g root -m 644 "$here/../../../tools/actions/container_manager.py" \
    "$container_manager"
install -D -o root -g root -m 644 "$here/../../../tools/helpers/images.py" \
    "$images_helper"
install -D -o root -g root -m 644 "$here/../../../tools/helpers/lxc.py" \
    "$lxc_helper"
sed -i -E 's/^(suspend_action[[:space:]]*=[[:space:]]*).*/\1none/' \
    "$waydroid_config"
install -d -m 755 /etc/systemd/system/waydroid-container.service.d
printf '[Service]\nEnvironment=WAYDROID_IPTABLES_BIN=/usr/bin/iptables\n' \
    >/etc/systemd/system/waydroid-container.service.d/10-waydroid-nft-backend.conf
systemctl daemon-reload
systemctl enable tft-waydroid-mask.service
systemctl restart tft-waydroid-mask.service

waydroid shell -- setprop persist.waydroid.fake_touch \
    com.riotgames.league.teamfighttactics,com.riotgames.league.teamfighttacticsvn
waydroid shell -- setprop persist.sys.locale vi-VN
waydroid shell -- settings put system screen_off_timeout 2147483647
waydroid shell -- svc power stayon true
waydroid shell -- cmd media_session volume --stream 3 --set 14

echo 'Installed. Restart waydroid-container, start the user session, and launch TFT.'
echo 'The user session regenerates TFT desktop entries with /usr/local/bin/tft-waydroid.'
