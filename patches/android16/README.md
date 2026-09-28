# TFT on the July 2026 WayDroid-ATV Android 16 image

This directory reproduces the compatibility changes tested on CachyOS with
TFT 18.3, x86_64 Waydroid, Intel graphics, KDE Wayland, and the Android 16
WayDroid-ATV vendor image dated 2026-07-17. It changes Waydroid's host code
and Android system overlay; it does **not** edit the TFT package or game data.

## Root causes and changes

1. **Compositor and input faults.** The July image's `hwcomposer.waydroid.so` (Build ID
   `518e927a66120147f1eedc924d230c04`) dereferences a null framebuffer
   target in `get_buffer_metadata_cros()+4`. The source fix landed in
   [WayDroid-ATV commit 2c141e2](https://github.com/WayDroid-ATV/android_hardware_waydroid/commit/2c141e27cc49d985418e891e59d75993a09a29f1)
   after this image. The same image ignores initial cursor coordinates in
   `pointer_handle_enter()`, so a click without prior motion reaches the input
   shim without a position. It also recreates the touch FIFO on duplicate
   `xdg_toplevel.configure` events, interrupting held drags.
   `0001-hwcomposer-skip-null-framebuffer-target.patch` backports all three
   corrections to source revision `831ba03`;
   `patch_hwcomposer_prebuilt.py` applies them to **only** the exact verified
   July binary.
   Its input SHA-256 is
   `9908498c71cbe8e52ec4bc4b532ebebcd6f55c0342590ecb63358c240757b931`,
   and its output SHA-256 is
   `741f75185a629cf5c362b349b4aa082e75b1ccb6aa3ecad30b160cbfbfe0b87d`.
   The installer reads the original from `vendor.img`; it does not overwrite
   the image.
2. **Early native crash.** TFT's ARM64 `libmvg.so` checks
   `/proc/<pid>/task/<tid>/syscall` and traps when exposed to the proc result
   provided by this Android container. The Android 16 NativeBridge v8 wrapper
   in `tft-compat/nativebridge_wrapper.c` pauses only TFT as it loads mVG.
   A root-owned service validates the stopped process and masks that one
   proc file with `/dev/null` in its mount namespace, then resumes it.
   Other apps and the game package are untouched. The wrapper delegates to
   WayDroid-ATV's `libndk_translation.so`. The July translator's 4 MiB JIT
   allocations eventually fill the kernel's default `MAP_32BIT` range at
   1–2 GiB, leaving free low addresses unused. The pinned
   `patch_berberis_prebuilt.py` retries only failed 4 MiB `MAP_32BIT`
   requests that started with a null address hint. It tries free addresses
   below 1 GiB without `MAP_FIXED`. Its input SHA-256
   is `fbadc774c989534a567e6af8fd16d2c00727b1f1d9cc778bf538d6b59ed9776d`;
   its output SHA-256 is
   `01dd4ed9c8117e77ae34d622bc24fd06ede46e8d456820c55e79a09b6312f992`.
   The installer restores the tested `lite-translate-or-interpret` mode.
3. **Network and suspend.** This fork's `waydroid-net.sh` accepts an iptables
   backend override and uses narrow DNS/forwarding rules; the installer
   chooses the nft backend used with the host firewall. This fork's
   `hardware_manager.py` accepts `suspend_action=none`. The installer sets it
   because Android's idle suspend previously froze the container while TFT
   was loading. It also keeps the Android display awake for this game setup.
4. **Input, language, menu.** TFT's Unreal menu requires touchscreen events;
   Android's normal mouse-button events only operate the Riot WebView. The
   HWC preload converts left-button press, held motion, and release into
   touchscreen packets while retaining pointer motion for coordinates. It
   reopens the touch FIFO for each packet because HWC recreates that FIFO on
   display resize; a stale
   writer could receive `SIGPIPE` and restart HWC and SurfaceFlinger. The
   installer also enables Waydroid's `fake_touch` option, sets `vi-VN`, sets
   Android media volume to 14/15, and installs `/usr/local/bin/tft-waydroid`.
   The launcher starts TFT before showing the full UI so the Waydroid host
   window remains visible.
5. **GPU selection after reboot.** On this Intel/NVIDIA host, DRM render node
   numbers swapped after a reboot. The init-time `waydroid_base.prop` and
   LXC device mount still targeted NVIDIA, making Waydroid fall back to
   ANGLE/SwiftShader OpenGL ES 3.1. TFT requires ES 3.2 and displayed an
   unsupported-device message. The container now regenerates its LXC device
   mounts and GBM property from Waydroid's supported GPU detector at every
   session start. It fails explicitly if GBM is configured but no supported
   render node exists.

## Vietnam release

The original XAPK had package `com.riotgames.league.teamfighttactics` and
installer `null` (installed via Android shell). After Riot sign-in it showed
a region notice on a Vietnam
connection. The [official Vietnam Google Play listing](https://play.google.com/store/apps/details?id=com.riotgames.league.teamfighttacticsvn)
is VNG's separate package, `com.riotgames.league.teamfighttacticsvn`.
The launcher accepts either exact package name and defaults to the Vietnam
package; each Waydroid-generated desktop entry passes its package explicitly
after the installer runs. The bridge watcher and touch shim also recognize
both packages. The Vietnam package was installed from Play with
`installerPackageName=com.android.vending`; it stores its assets separately.
The original XAPK was moved to Trash by the user. The user later uninstalled
the original Android package, which removed its Android app data.

## 4K display and game render size

The Waydroid display is 3840×2160, but TFT's selected Android device profile
sets Unreal's `r.MobileContentScaleFactor=1.0`. SurfaceFlinger showed that the
game's SurfaceView supplied 1280×720 pixels and was enlarged 3×. The in-game
“Ultra” graphics option did not change that buffer size. Epic's
[mobile resolution documentation](https://dev.epicgames.com/documentation/unreal-engine/performance-guidelines-for-mobile-devices-in-unreal-engine)
describes 1.0 as 720p on Android.

TFT's APK reads `UECommandLine.txt` from its private app data. The following
helper writes only that external command-line file, preserving the signed APK
and downloaded assets. It refuses to overwrite an unrelated command line.
The setting persists across Waydroid restarts and takes effect when TFT is
launched again:

```sh
sudo tft-waydroid-resolution 2k
# Optional: 4k or stock in place of 2k, then restart only TFT.
```

On this Intel UHD 770 host, SurfaceFlinger measured 2560×1440 rendering at
approximately 60 FPS in the store and 3840×2160 at approximately 33 FPS
during startup. These are different scenes, so they are a responsiveness
check rather than a controlled benchmark. The 2K setting is the chosen
balance for smoother input. The 4K setting remains available for later
testing, but the helper does not change the resolution during installation.

## Reinstall on the same image

The installer requires a running Android 16 Waydroid container with the July
system and vendor images at `/etc/waydroid-extra/images`. It needs `clang`,
`cc` with static glibc support, `debugfs`, EROFS mount support, `nsenter`, LXC tools, systemd, and
root access. TFT must be installed separately; this repository intentionally
contains no Riot binaries, account data, or downloaded game assets.

```sh
# Run this with an Android 16 Waydroid session already active.
sudo ./patches/android16/tft-compat/install.sh
waydroid session stop
sudo systemctl restart waydroid-container.service
waydroid session start &
/usr/local/bin/tft-waydroid
```

The installer is idempotent for this exact image and refuses an unfamiliar
hwcomposer SHA or conflicting NativeBridge settings. The Android user-data
directory must be retained to preserve the downloaded TFT patch. To restore
stock behavior, use a clean Waydroid image/profile and remove this fork's
service and installed overlays; do not change the original vendor image.

## Source rebuild path

The manifest puts the Android hardware source at `hardware/waydroid`. With an
Android 16 product build environment, apply the source backport to the July
revision and rebuild the module:

```sh
WAYDROID_PATCH="$(realpath patches/android16/0001-hwcomposer-skip-null-framebuffer-target.patch)"
git -C "$ANDROID_BUILD_TOP/hardware/waydroid" fetch --depth=1 origin 831ba03fd34f810e13c079e03ac1340bbcd0b7f9
git -C "$ANDROID_BUILD_TOP/hardware/waydroid" checkout --detach FETCH_HEAD
git -C "$ANDROID_BUILD_TOP/hardware/waydroid" apply --check "$WAYDROID_PATCH"
git -C "$ANDROID_BUILD_TOP/hardware/waydroid" apply "$WAYDROID_PATCH"
cd "$ANDROID_BUILD_TOP"
m hwcomposer.waydroid
```

The source patch applied cleanly to `831ba03`. The exact binary backport,
rather than a full image rebuild, was installed and tested on this machine.

The regression checks exercise the pinned binary patch and reproduce the
touch FIFO replacement that previously killed the HWC process with `SIGPIPE`:

```sh
debugfs -R "dump /lib64/hw/hwcomposer.waydroid.so /tmp/hwc-original.so" /etc/waydroid-extra/images/vendor.img
python3 patches/android16/test_patch_hwcomposer_prebuilt.py /tmp/hwc-original.so
cc -Wall -Wextra -Werror -Dopen=test_open -Dreadlink=test_readlink -c patches/android16/tft-compat/pointer_touch.c -o /tmp/tft-pointer.o
cc -Wall -Wextra -Werror patches/android16/tft-compat/test_pointer_touch.c /tmp/tft-pointer.o -ldl -pthread -o /tmp/tft-pointer-test
/tmp/tft-pointer-test
bash patches/android16/tft-compat/test_launch_tft.sh
PYTHONPATH=. python3 patches/android16/test_dynamic_gpu.py
sudo bash patches/android16/test_berberis_mmap.sh
```

## Runtime evidence and limits

- `tft-waydroid-mask.service` logged `TFT ... mask=ok` during a fresh
  launcher start; `libmvg.so` loaded and Unreal's `GameActivity` ran.
- The game reached its 3840×2160 landscape login menu in Vietnamese after a
  clean container restart. The HWC process loaded the patched vendor binary
  and preload overlay from the expected inodes.
- Resetting the shim's `have_position` to zero and recreating the Waydroid
  window set it back to one through HWC pointer input. A one-shot breakpoint
  confirmed the patched `pointer_handle_enter` callback ran with Wayland
  surface coordinates.
- A press and release injected through the HWC process's **preloaded `write`**
  function at `(1920, 1400)` opened Riot's `MobileFREWebViewActivity`; its
  Vietnamese login form rendered. This verifies the HWC-to-touch path without
  using Android's direct `input tap` command. HWC kept the same PID through
  that transition, with no `SIGPIPE` in the post-restart init journal.
  Credentials and match play were not tested.
- The Vietnam Play package loaded `GameActivity` with watcher `mask=ok`.
  Before the Berberis patch, it crashed twice at the 4 MiB executable mmap;
  `interpret-only` avoided the crash but used roughly three CPU cores and
  took several minutes to reach Riot WebView. After the pinned retry patch,
  a clean boot's guest mmap probe passed and the package reached WebView in
  about 26 seconds without a new Berberis tombstone.
- With the duplicate-configure HWC patch loaded, Android registered
  `wayland_touch` once after boot; the prior session registered it dozens of
  times at an unchanged 3840×2160 resolution. HWC kept its PID through the
  check.
- The Play package has its own downloaded assets. The user handled Riot
  sign-in directly and reached the game lobby; this installer and its
  diagnostic tools did not handle credentials. Match play remains untested.
- A direct HWC input test observed touch down, held move, and touch up in
  order (1, 1, 0), while the unit test covered FIFO rotation and lost-release
  recovery. Physical gameplay dragging has not been confirmed.
- A clean session started from deliberately stale `renderD129` host config.
  The generated guest property and LXC mount both selected Intel `renderD128`;
  guest EGL was Mesa. On the prior boot, SurfaceFlinger reported Intel Mesa
  OpenGL ES 3.2 and the game lobby loaded.
- Android stream 3 was 14/15 after the clean restart. PipeWire showed an
  unmuted Waydroid stream on the HDMI sink, and the user confirmed hearing
  game audio through the monitor.

This is intentionally pinned to the July 2026 image. An updated Android
image or translator may have different ABI and HWC bytes; the installer
refuses those versions until the compatibility changes are reviewed.
