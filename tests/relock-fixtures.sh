#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks every lockfile of this repository with the clojure-cli-purifier
# command of this checkout: each test fixture, the deploy tool, and
# honeysql at the commit tests/default.nix builds. Each keeps the build and
# test commands and the source root of its lockfile. The lock runs download
# Maven Central's files from Google's mirror of it, as the lockfiles were
# made. CI's conformance-relock job runs it and fails when a lockfile
# changes. It needs the network, and it runs from any directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(nix build --no-link --print-out-paths "$root#cli")/bin/clojure-cli-purifier
mirror=central=https://maven-central.storage-download.googleapis.com/maven2/
work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier-relock.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
# The lock runs take no aliases from the user's configuration.
mkdir -p "$work/config"
echo '{}' >"$work/config/deps.edn"
export CLJ_CONFIG="$work/config"

{
  find "$root/tests/fixtures" -name clojure-cli-purifier.lock.json -exec dirname {} \;
  echo "$root/pkgs/clojure-cli-purifier/deploy"
} | sort | while IFS= read -r project; do
  echo "== $project"
  (cd "$project" && "$cli" lock --force --mirror "$mirror")
done

echo "== honeysql"
honeysql=$(nix eval --raw --impure --expr '(builtins.fetchTree {
  type = "github";
  owner = "seancorfield";
  repo = "honeysql";
  rev = "1cc6bbed923bacdffe8cf727ef044e924d2a3597";
  narHash = "sha256-ung2gdsJ3LdKJxK/eBwJqXNIr7JzK4DJ2enShl9XLE4=";
}).outPath')
cp -r "$honeysql" "$work/honeysql"
chmod -R u+w "$work/honeysql"
(cd "$work/honeysql" && "$cli" lock --force --mirror "$mirror" \
  --lockfile "$root/tests/real-world/honeysql/clojure-cli-purifier.lock.json")
