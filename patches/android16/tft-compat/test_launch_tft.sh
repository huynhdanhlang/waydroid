#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
cat >"$test_dir/waydroid" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TFT_TEST_LOG"
EOF
chmod +x "$test_dir/waydroid"
export PATH="$test_dir:$PATH" TFT_TEST_LOG="$test_dir/calls"

"$here/launch-tft.sh" com.riotgames.league.teamfighttacticsvn
printf '%s\n' \
    'app launch com.riotgames.league.teamfighttacticsvn' \
    'show-full-ui' >"$test_dir/expected"
cmp "$test_dir/expected" "$TFT_TEST_LOG"

: >"$TFT_TEST_LOG"
"$here/launch-tft.sh" com.riotgames.league.teamfighttactics
printf '%s\n' \
    'app launch com.riotgames.league.teamfighttactics' \
    'show-full-ui' >"$test_dir/expected"
cmp "$test_dir/expected" "$TFT_TEST_LOG"

: >"$TFT_TEST_LOG"
"$here/launch-tft.sh" --quit
printf '%s\n' 'session stop' >"$test_dir/expected"
cmp "$test_dir/expected" "$TFT_TEST_LOG"

: >"$TFT_TEST_LOG"
if "$here/launch-tft.sh" com.example.other >/dev/null 2>&1; then
    echo 'unknown package was accepted' >&2
    exit 1
fi
[[ ! -s $TFT_TEST_LOG ]] || { echo 'unknown package was launched' >&2; exit 1; }
echo 'launcher selects TFT packages and can quit Waydroid'
