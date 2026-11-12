# SPDX-License-Identifier: MIT
#
# The gitlibs directory of a lockfile, in the layout the Clojure CLI keeps
# under GITLIBS.
#
# `libs/<lib>/<commit>` is the checkout of a git dependency, a link to its
# fetch by the shared purifier library. `_repos/<scheme>/<host>/<path>` is
# the bare repository
# the CLI expands a short commit and checks a tag in. It is rebuilt here
# without the network: the files of each locked checkout are added as a
# tree, every recorded commit object is written back, the repository is
# marked shallow at the recorded commits, and each recorded tag points at
# its commit. Each commit object carries the hash of its tree and of its
# parents, so a rebuilt commit has exactly the locked commit hash, and the
# builder checks that it does.
{
  lib,
  runCommand,
  jq,
  git,
  # The functions of the shared purifier library.
  purifier,
  # The lock in memory, from read-lock.nix and checkLock.
  lock,
  # The Nix system whose entries the gitlibs directory holds.
  system,
  # The packages that `fetchEntry` takes by name: fetchurl, fetchgit,
  # runCommand, unzip, zstd, python3 and writeText. A fetcher given here
  # replaces nixpkgs' own.
  fetchers,
}:
let
  fetch = purifier.fetchEntry fetchers;
  gitEntries = builtins.filter (entry: entry ? git) (purifier.entriesFor system lock);

  # One line per locked checkout: its path under GITLIBS, its repository
  # URL and its store path.
  checkouts = lib.concatMapStrings (
    entry: "${entry.path}\t${entry.git.url}\t${fetch entry}\n"
  ) gitEntries;
in
runCommand "clojure-cli-purifier-gitlibs"
  {
    nativeBuildInputs = [
      jq
      git
    ];
    inherit checkouts;
    repos = builtins.toJSON lock.lockfile.gitRepos;
    passAsFile = [
      "checkouts"
      "repos"
    ];
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    mkdir -p $out/libs
    while IFS=$'\t' read -r rel url target; do
      mkdir -p "$out/$(dirname "$rel")"
      ln -s "$target" "$out/$rel"
    done < "$checkoutsPath"

    count=$(jq length "$reposPath")
    for ((i = 0; i < count; i++)); do
      repo() { jq -r --argjson i "$i" ".[\$i]$1" "$reposPath"; }
      rel=$(repo .path)
      url=$(repo .url)
      bare="$out/$rel"
      git init --quiet --bare "$bare"

      # The trees of the checkouts of this repository.
      while IFS=$'\t' read -r _ checkoutUrl target; do
        [ "$checkoutUrl" = "$url" ] || continue
        GIT_INDEX_FILE="$TMPDIR/index" git --git-dir="$bare" --work-tree="$target" \
          -c core.autocrlf=false add --all --force .
        GIT_INDEX_FILE="$TMPDIR/index" git --git-dir="$bare" write-tree >/dev/null
        rm -f "$TMPDIR/index"
      done < "$checkoutsPath"

      commits=$(jq --argjson i "$i" '.[$i].commits | length' "$reposPath")
      for ((c = 0; c < commits; c++)); do
        want=$(jq -r --argjson i "$i" --argjson c "$c" '.[$i].commits[$c].sha' "$reposPath")
        got=$(jq -j --argjson i "$i" --argjson c "$c" '.[$i].commits[$c].object' "$reposPath" |
          git --git-dir="$bare" hash-object -t commit -w --stdin)
        if [ "$got" != "$want" ]; then
          echo "clojure-cli-purifier: the recorded commit $want of $url rebuilt as $got" >&2
          exit 1
        fi
      done
      repo '.shallow[]' >"$bare/shallow"
      while IFS=$'\t' read -r tag sha; do
        git --git-dir="$bare" update-ref "refs/tags/$tag" "$sha"
      done < <(repo '.tags | to_entries[] | "\(.key)\t\(.value)"')

      # Every checkout must rebuild the tree its commit names. A checkout
      # whose files differ from that tree, such as one changed by a git
      # attribute, would leave the commit without its tree.
      while IFS=$'\t' read -r rel2 checkoutUrl _; do
        [ "$checkoutUrl" = "$url" ] || continue
        sha=$(basename "$rel2")
        if ! git --git-dir="$bare" cat-file -e "$sha^{tree}" 2>/dev/null; then
          echo "clojure-cli-purifier: the checkout of $url at $sha does not rebuild the tree of its commit" >&2
          exit 1
        fi
      done < "$checkoutsPath"
    done
  ''
