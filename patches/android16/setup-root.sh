#!/usr/bin/env bash
# Privileged half of setup.sh. Run only through sudo from a local checkout.
set -euo pipefail

if (( EUID != 0 )); then
    echo 'setup-root.sh must run as root.' >&2
    exit 1
fi
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
image_dir=/etc/waydroid-extra/images
cache_dir=/var/cache/tft-waydroid-images
release=https://github.com/WayDroid-ATV/waydroid-builds/releases/download/20260717
system_zip=lineage-23.2-20260717-GAPPS-waydroid_x86_64-system.zip
vendor_zip=lineage-23.2-20260717-MAINLINE-waydroid_x86_64-vendor.zip
system_zip_sha=f64a746f2ec50417ebb363ad1da1104d5cc71bb39d89ff21a264b5cacaeb006a
vendor_zip_sha=28dfbd0e423dff6d5c7d2e34e15011fbaf4865da769d9923b84656d87e9f4d3c
system_img_sha=582629757cb379f3e6699d1681e3358d2c6f82cf08b8ce1f1c1584e22d409aff
vendor_img_sha=63e002329543ef42a67cc6cfcd40655060ccdd6d00f87bbcc7510683cf07cf72

if [[ $(uname -m) != x86_64 ]]; then
    echo 'This pinned Android 16 image supports x86_64 hosts only.' >&2
    exit 1
fi
if [[ ! -f /etc/os-release ]] || ! grep -Eq '^ID=(cachyos|arch)$' /etc/os-release; then
    echo 'This one-command setup has been verified only for CachyOS/Arch.' >&2
    exit 1
fi
supported_gpu=0
for render in /dev/dri/renderD*; do
    [[ -e $render ]] || continue
    driver=$(sed -n 's/^DRIVER=//p' "/sys/class/drm/${render##*/}/device/uevent" 2>/dev/null | head -1)
    case $driver in
        i915|xe|amdgpu|nouveau) supported_gpu=1; break ;;
    esac
done
if (( ! supported_gpu )); then
    echo 'No verified Intel/AMD/nouveau DRM render node found on this PC.' >&2
    exit 1
fi

valid_sha() {
    local expected=$1 file=$2
    [[ -f $file ]] && printf '%s  %s\n' "$expected" "$file" | sha256sum --status -c -
}
for image in system vendor; do
    if [[ -f $image_dir/$image.img ]]; then
        expected=${image}_img_sha
        if ! valid_sha "${!expected}" "$image_dir/$image.img"; then
            echo "Existing $image.img differs from the verified July 2026 image; refusing to replace it." >&2
            exit 1
        fi
    fi
done
config=/var/lib/waydroid/waydroid.cfg
if [[ -f $config ]] &&
   ! { grep -Eq '^images_path[[:space:]]*=[[:space:]]*/etc/waydroid-extra/images$' "$config" &&
       grep -Eq '^arch[[:space:]]*=[[:space:]]*x86_64$' "$config" &&
       grep -Eq '^vendor_type[[:space:]]*=[[:space:]]*MAINLINE$' "$config"; }; then
    echo 'Existing Waydroid configuration uses a different image/profile; refusing to overwrite it.' >&2
    exit 1
fi

if pacman -Q waydroid >/dev/null 2>&1; then
    installed=$(pacman -Q waydroid | awk '{print $2}')
    [[ $installed == 1.6.3-* ]] || {
        echo "Waydroid $installed is untested; expected 1.6.3.x. No packages changed." >&2
        exit 1
    }
    packages=(clang lld gcc e2fsprogs unzip curl iptables)
else
    available=$(pacman -Si waydroid | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -1)
    [[ $available == 1.6.3-* ]] || {
        echo "Repository Waydroid $available is untested; expected 1.6.3.x. No packages changed." >&2
        exit 1
    }
    packages=(waydroid clang lld gcc e2fsprogs unzip curl iptables)
fi
pacman -S --needed --noconfirm "${packages[@]}"

download_image() {
    local archive=$1 archive_sha=$2 image=$3 image_sha=$4
    local zip_path=$cache_dir/$archive
    local extracted=$cache_dir/$image
    local installed=$image_dir/$image
    if ! valid_sha "$archive_sha" "$zip_path"; then
        if ! curl --fail --location --retry 5 --retry-delay 3 --continue-at - \
            --output "$zip_path" "$release/$archive" ||
           ! valid_sha "$archive_sha" "$zip_path"; then
            echo "Retrying $archive from byte zero after failed resume/checksum."
            if [[ -e $zip_path ]]; then unlink "$zip_path"; fi
            curl --fail --location --retry 5 --retry-delay 3 \
                --output "$zip_path" "$release/$archive"
            valid_sha "$archive_sha" "$zip_path" || {
                echo "Archive checksum mismatch: $archive" >&2; exit 1;
            }
        fi
    fi
    unzip -p "$zip_path" "$image" >"$extracted"
    valid_sha "$image_sha" "$extracted" || {
        echo "Extracted image checksum mismatch: $image" >&2; exit 1;
    }
    install -m 644 "$extracted" "$installed.new"
    valid_sha "$image_sha" "$installed.new" || {
        echo "Installed image checksum mismatch: $installed.new" >&2; exit 1;
    }
    mv -f -- "$installed.new" "$installed"
    unlink "$extracted"
    unlink "$zip_path"
}

if [[ ! -f $image_dir/system.img || ! -f $image_dir/vendor.img ]]; then
    available_kib=$(df -Pk /var/cache | awk 'NR==2 {print $4}')
    if (( available_kib < 6 * 1024 * 1024 )); then
        echo 'At least 6 GiB free space is required to download and extract the pinned images.' >&2
        exit 1
    fi
    install -d -m 755 "$cache_dir" "$image_dir"
    if [[ ! -f $image_dir/system.img ]]; then
        download_image "$system_zip" "$system_zip_sha" system.img "$system_img_sha"
    fi
    if [[ ! -f $image_dir/vendor.img ]]; then
        download_image "$vendor_zip" "$vendor_zip_sha" vendor.img "$vendor_img_sha"
    fi
fi
echo 'Verified Android 16 system and vendor images.'

if [[ -f $config ]]; then
    echo 'Preserving existing Waydroid configuration and Android user data.'
else
    waydroid init -f
fi
if [[ $(grep -c '^suspend_action[[:space:]]*=' "$config") != 1 ]]; then
    echo 'Expected exactly one suspend_action setting after Waydroid init.' >&2
    exit 1
fi
sed -i -E 's/^(suspend_action[[:space:]]*=[[:space:]]*).*/\1none/' "$config"

# The first Android boot needs the host's firewall backend before the full
# compatibility installer can access the guest's Bionic libraries.
install -m 755 "$here/../../data/scripts/waydroid-net.sh" \
    /usr/lib/waydroid/data/scripts/waydroid-net.sh
install -d -m 755 /etc/systemd/system/waydroid-container.service.d
printf '[Service]\nEnvironment=WAYDROID_IPTABLES_BIN=/usr/bin/iptables\n' \
    >/etc/systemd/system/waydroid-container.service.d/10-waydroid-nft-backend.conf
systemctl daemon-reload
systemctl enable --now waydroid-container.service
echo 'Waydroid host, pinned images, and container service are ready.'
