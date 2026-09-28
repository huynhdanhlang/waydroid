#!/usr/bin/env bash
# Set TFT's Unreal render size without modifying the Play Store APK.
set -euo pipefail

if (( EUID != 0 )) || (( $# < 1 || $# > 2 )); then
    echo 'Usage (as root): tft-waydroid-resolution 2k|4k|stock [package]' >&2
    exit 2
fi

mode=$1
package=${2:-com.riotgames.league.teamfighttacticsvn}
case $package in
    com.riotgames.league.teamfighttactics|com.riotgames.league.teamfighttacticsvn) ;;
    *) echo "Unsupported TFT package: $package" >&2; exit 2 ;;
esac
case $mode in
    2k) resolution='2560 -mobileresy=1440' ;;
    4k) resolution='3840 -mobileresy=2160' ;;
    stock) resolution='' ;;
    *) echo "Unsupported resolution: $mode" >&2; exit 2 ;;
esac

prop_file=/var/lib/waydroid/waydroid.prop
[[ -f $prop_file ]] || { echo "Missing $prop_file" >&2; exit 1; }
data_root=$(sed -n 's/^waydroid.host_data_path=//p' "$prop_file")
[[ $data_root == /* && $data_root != *$'\n'* ]] || {
    echo 'Invalid Waydroid user-data path' >&2; exit 1;
}
files_dir=$data_root/data/$package/files
[[ -d $files_dir ]] || { echo "TFT app data not found: $files_dir" >&2; exit 1; }
owner=$(stat -c '%u:%g' "$files_dir")
target_dir=$files_dir/UnrealGame/TFT
target=$target_dir/UECommandLine.txt
prefix='../../../TFT/TFT.uproject -mobileresx='

if [[ -e $target ]]; then
    current=$(<"$target")
    case $current in
        "$prefix"'2560 -mobileresy=1440'|"$prefix"'3840 -mobileresy=2160') ;;
        *) echo "Refusing to replace an unrelated Unreal command line: $target" >&2; exit 1 ;;
    esac
fi

if [[ $mode == stock ]]; then
    if [[ -e $target ]]; then unlink "$target"; fi
    echo 'TFT will use its default render size after the next app launch.'
    exit 0
fi

install -d -m 755 -o "${owner%%:*}" -g "${owner##*:}" "$target_dir"
temp=$(mktemp "$target_dir/.UECommandLine.XXXXXX")
trap 'if [[ -e $temp ]]; then unlink "$temp"; fi' EXIT
printf '%s%s\n' "$prefix" "$resolution" >"$temp"
chown "$owner" "$temp"
chmod 644 "$temp"
mv -f -- "$temp" "$target"
echo "TFT will render at ${resolution%% *} pixels wide after the next app launch."
