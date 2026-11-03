#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check of the purifier contract, on a copy of the
# hello fixture. Its :range alias takes org.clojure/core.memoize in the
# range [1.0.257,1.1.266]. The copy's lockfile pins an old version: its
# recorded version list of core.memoize ends at 1.0.257, as if the lock ran
# before 1.1.266 was out.
#
#   - `clojure-cli-purifier lock --force` keeps 1.0.257, the version the
#     lockfile resolved the range to, beside the 1.1.266 that tools.build
#     needs;
#   - `clojure-cli-purifier update org.clojure/core.memoize` resolves the
#     range anew, to 1.1.266, and the lockfile then passes the stale check.
#
# It needs the network, and it runs from any directory.
# shellcheck disable=SC2016 # the $ names in single quotes are jq variables
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/clojure-cli-purifier
jq=$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#jq^bin')/bin/jq
sha256sum=$(nix build --no-link --print-out-paths --inputs-from "$root" 'nixpkgs#coreutils')/bin/sha256sum
mirror=central=https://maven-central.storage-download.googleapis.com/maven2/
work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier-update.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
mkdir -p "$work/config"
echo '{}' >"$work/config/deps.edn"
export CLJ_CONFIG="$work/config"
cp -r "$root/tests/fixtures/hello" "$work/hello"
chmod -R u+w "$work/hello"
cd "$work/hello"
lock=clojure-cli-purifier.lock.json
memoize=org/clojure/core.memoize

# The version of core.memoize the lockfile holds.
memoizeVersion() {
  "$jq" -r --arg dir "$memoize/" \
    '[.artifacts[].path | select(startswith($dir) and endswith(".jar")) | split("/")[3]] | unique | join(" ")' "$lock"
}

echo "== a lockfile whose version list of core.memoize ends at 1.0.257"
"$jq" --arg path "$memoize/maven-metadata-central.xml" \
  '(.metadata[] | select(.path == $path) | .contents) |= (
     gsub("<version>(1\\.1\\.266|1\\.2\\.[0-9]+)</version>\\s*"; "")
     | gsub("<latest>[^<]*</latest>"; "<latest>1.0.257</latest>")
     | gsub("<release>[^<]*</release>"; "<release>1.0.257</release>"))' \
  "$lock" >"$lock.old"
# The edited lockfile gets the contentHash a lock run would give it.
hash=$("$jq" -S -c 'del(.contentHash)' "$lock.old" | tr -d '\n' | "$sha256sum" | cut -d' ' -f1)
"$jq" --arg hash "$hash" '.contentHash = $hash' "$lock.old" >"$lock"
rm "$lock.old"

# tools.build depends on core.memoize 1.1.266, so every lock holds that
# version. The range of the :range alias adds a second version when the
# version list ends below it.
echo "== lock keeps the version the lockfile resolved the range to"
"$cli" lock --force --mirror "$mirror"
test "$(memoizeVersion)" = "1.0.257 1.1.266"

echo "== update resolves the range anew"
"$cli" update org.clojure/core.memoize --mirror "$mirror"
test "$(memoizeVersion)" = 1.1.266
"$cli" lock | grep -q 'is up to date'

echo "== all update checks passed"
