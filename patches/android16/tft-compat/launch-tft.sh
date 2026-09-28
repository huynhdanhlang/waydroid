#!/usr/bin/env bash
# Keep the full-UI host window visible while launching TFT from a desktop menu.
set -euo pipefail
if (( $# > 1 )); then
    echo 'Expected one TFT package name.' >&2
    exit 2
fi
if [[ ${1:-} == --quit ]]; then
    waydroid session stop
    exit 0
fi
package=${1:-com.riotgames.league.teamfighttacticsvn}
case $package in
    com.riotgames.league.teamfighttactics|com.riotgames.league.teamfighttacticsvn) ;;
    *) echo "Unsupported TFT package: $package" >&2; exit 2 ;;
esac
waydroid app launch "$package"
waydroid show-full-ui
