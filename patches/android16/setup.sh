#!/usr/bin/env bash
# One-command CachyOS setup for the verified Waydroid Android 16 profile.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=${1:-install}
if [[ $mode != install && $mode != --check ]] || (( $# > 1 )); then
    echo 'Usage: bash patches/android16/setup.sh [--check]' >&2
    exit 2
fi
if (( EUID == 0 )); then
    echo 'Run this as your desktop user; it requests sudo for system changes.' >&2
    exit 2
fi
if [[ $(uname -m) != x86_64 || ${XDG_SESSION_TYPE:-} != wayland ||
      -z ${XDG_RUNTIME_DIR:-} || -z ${WAYLAND_DISPLAY:-} ]]; then
    echo 'Requires an x86_64 desktop logged into a Wayland session.' >&2
    exit 1
fi
if [[ $WAYLAND_DISPLAY == /* ]]; then
    wayland_socket=$WAYLAND_DISPLAY
else
    wayland_socket=$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
fi
[[ -S $wayland_socket ]] || {
    echo "Wayland socket is not available: $wayland_socket" >&2
    exit 1
}
if [[ ! -f /etc/os-release ]] || ! grep -Eq '^ID=(cachyos|arch)$' /etc/os-release; then
    echo 'This one-command setup is supported on CachyOS/Arch only.' >&2
    exit 1
fi
for file in "$here/setup-root.sh" "$here/tft-compat/install.sh" \
            "$here/patch_hwcomposer_prebuilt.py" "$here/patch_berberis_prebuilt.py"; do
    [[ -f $file ]] || { echo "Missing setup source: $file" >&2; exit 1; }
done

if [[ $mode == --check ]]; then
    echo 'Host architecture and Wayland session: supported.'
    if pacman -Q waydroid >/dev/null 2>&1; then
        installed=$(pacman -Q waydroid | awk '{print $2}')
        [[ $installed == 1.6.3-* ]] || {
            echo "Waydroid $installed is untested; expected 1.6.3.x." >&2; exit 1;
        }
        echo "Waydroid $installed is installed."
    else
        available=$(pacman -Si waydroid | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -1)
        [[ $available == 1.6.3-* ]] || {
            echo "Repository Waydroid $available is untested; expected 1.6.3.x." >&2; exit 1;
        }
        echo "Waydroid $available is available for installation."
    fi
    if [[ -f /etc/waydroid-extra/images/system.img &&
          -f /etc/waydroid-extra/images/vendor.img ]]; then
        echo 'Local Android images exist; setup will verify both SHA-256 checksums.'
    else
        echo 'Setup will download the pinned July 2026 GAPPS system and MAINLINE vendor images.'
    fi
    echo 'No changes made.'
    exit 0
fi

command -v sudo >/dev/null || { echo 'sudo is required.' >&2; exit 1; }
command -v systemd-run >/dev/null || { echo 'systemd-run is required.' >&2; exit 1; }
systemctl --user show-environment >/dev/null || {
    echo 'The desktop user systemd session is not available.' >&2; exit 1;
}
sudo bash "$here/setup-root.sh"

start_session() {
    if ! waydroid status 2>/dev/null | grep -Eq '^Session:[[:space:]]*RUNNING$'; then
        session_unit="tft-waydroid-session-$(date +%s)-$$"
        systemd-run --user --unit="$session_unit" --collect --property=Type=exec \
            --setenv="WAYLAND_DISPLAY=$WAYLAND_DISPLAY" \
            --setenv="XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
            --setenv="DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}" \
            /usr/bin/waydroid session start
    fi
    local deadline=$((SECONDS + 180))
    while (( SECONDS < deadline )); do
        if waydroid status 2>/dev/null | grep -Eq '^Session:[[:space:]]*RUNNING$' &&
           [[ $(waydroid prop get sys.boot_completed 2>/dev/null) == 1 ]]; then
            return 0
        fi
        sleep 2
    done
    echo 'Android did not finish booting within 180 seconds.' >&2
    if [[ -n ${session_unit:-} ]]; then
        journalctl --user -u "$session_unit" -n 20 --no-pager >&2 || true
    fi
    exit 1
}

start_session
sudo bash "$here/tft-compat/install.sh"
waydroid session stop
sudo systemctl restart waydroid-container.service
start_session
waydroid show-full-ui

cat <<'EOF'
Waydroid is ready. Sign in to Google Play and install compatible Android apps.
For TFT in Vietnam, install "Đấu Trường Chân Lý" from Play (package
com.riotgames.league.teamfighttacticsvn). Then, for sharper 1440p rendering,
run: sudo tft-waydroid-resolution 2k
EOF
