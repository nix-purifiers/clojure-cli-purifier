# SPDX-License-Identifier: MIT
#
# clojure-cli-purifier: locks the downloads of a deps.edn project,
# prefetches them for the Clojure CLI, and publishes what Nix built.
#
# The package sets PURIFIER_LIB (the Nix library, nix/lib), PURIFIER_FORMAT
# (the lock format version it reads), PURIFIER_HELPER (helper.clj),
# PURIFIER_TOOLS_JAR (the tools jar of the Clojure CLI, which runs the
# helper), PURIFIER_NIXPKGS (the nixpkgs source the package was built from),
# PURIFIER_SHARED_REF (the flake reference of the shared purifier library)
# and JAVA_CMD (the JVM of the Clojure CLI).

lockName=clojure-cli-purifier.lock.json
# What `update` re-resolves: every library, or the libraries whose metadata
# lies under these directories of the local repository.
updateAll=0
updatePrefixes=()

usage() {
  cat <<'EOF'
Usage:
  clojure-cli-purifier lock [--lockfile PATH] [--force] [--build ARGS]... [--test ARGS]...
                            [--alias :NAME]... [--user-aliases]
                            [--source DIR] [--mirror ID=URL]...
      Runs the project with an empty local Maven repository and an empty
      gitlibs directory, and records every file the Clojure CLI downloads,
      the outputs of the build commands and the commands themselves in
      clojure-cli-purifier.lock.json.

      --build ARGS   A Clojure CLI command line the Nix build runs, such as
                     "-T:build uber". It may repeat. The default is the
                     uber or jar function of build.clj, when there is one
                     and deps.edn has a :build alias.
      --test ARGS    A Clojure CLI command line the Nix build runs when its
                     checks are on, such as "-M:test". It may repeat.
      --alias :NAME  An alias to prepare. The default is every alias of
                     deps.edn. It may repeat.
      --user-aliases Also prepares the aliases of the user deps.edn, for
                     the interactive mode. The Nix build ignores them.
                     --no-user-aliases stops preparing them.
      --source DIR   The directory that holds the project and the local
                     dependencies outside it, such as the root of a
                     repository with several projects. The Nix build takes
                     it as src. The default is the project root.
      --mirror ID=URL
                     Downloads the files of the repository ID, such as
                     central, from a mirror at URL during the lock run.
                     The lockfile names each such file by its URL in the
                     repository, with the mirror as a fallback. It may
                     repeat.

      Each option replaces its part of an existing lockfile, and a relock
      keeps every part no option names. Without options or --force, an
      up-to-date lockfile is left as it is. A relock keeps the versions
      the lockfile resolved its version ranges and SNAPSHOTs to.
  clojure-cli-purifier update [--lockfile PATH] [--mirror ID=URL]... [LIB]...
      Relocks the project and resolves the version ranges and SNAPSHOTs of
      every library anew, or those of the named libraries, such as
      org.clojure/core.memoize. Versions that deps.edn names exactly change
      only when deps.edn does.
  clojure-cli-purifier prefetch [--lockfile PATH]
      Builds the locked downloads into the Nix store, keeps them alive with
      a GC root in .clojure-cli-purifier beside the lockfile, and links
      .clojure-cli-purifier/bin/clojure. With that directory first on PATH,
      `clojure` runs on the locked downloads alone, with no network.
  clojure-cli-purifier publish [--lockfile PATH] [--repository ID=URL] [--dry-run]
      Builds the release of the project with Nix and deploys its jar and
      POM, without compiling anything outside the sandbox. The default
      repository is Clojars, with CLOJARS_USERNAME and CLOJARS_PASSWORD.
      Another repository takes its credentials from the server of the same
      id in ~/.m2/settings.xml.

  Every command takes --lockfile PATH, for a lockfile kept outside the
  project. The environment variable CLOJURE_CLI_PURIFIER_LOCKFILE gives the
  same path, and --lockfile takes precedence over it. The default is
  clojure-cli-purifier.lock.json in the project root.
EOF
}

die() {
  echo "clojure-cli-purifier: $*" >&2
  exit 1
}

# The project root: the nearest directory, from here upwards, that holds
# deps.edn.
projectRoot() {
  local dir
  dir=$(pwd)
  while [ "$dir" != / ]; do
    if [ -f "$dir/deps.edn" ]; then
      echo "$dir"
      return
    fi
    dir=$(dirname "$dir")
  done
  die "no deps.edn in $(pwd) or above it"
}

clojureVersion() {
  clojure --version | sed -n 's/^Clojure CLI version //p'
}

javaVersion() {
  "$JAVA_CMD" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.version = //p'
}

helper() {
  "$JAVA_CMD" -cp "$PURIFIER_TOOLS_JAR" clojure.main "$PURIFIER_HELPER" "$@"
}

# The lockfile of the project at root: the path given to --lockfile, then
# the path in CLOJURE_CLI_PURIFIER_LOCKFILE, then clojure-cli-purifier.lock.json
# in the project root. It prints an absolute path.
lockFileOf() {
  local root=$1 given=$2 path
  path=${given:-${CLOJURE_CLI_PURIFIER_LOCKFILE:-$root/$lockName}}
  case $path in
  /*) echo "$path" ;;
  *) echo "$(pwd)/$path" ;;
  esac
}

# Prints why the lockfile does not fit the project at root, with the
# command that fixes it, or nothing when the lockfile was made from this
# project definition, by this lock format and with this Clojure CLI.
lockProblem() {
  local root=$1 lockFile=$2 files sourceRoot
  if [ ! -f "$lockFile" ]; then
    echo "$lockFile does not exist; run clojure-cli-purifier lock"
    return
  fi
  if ! jq -e 'type == "object"' "$lockFile" >/dev/null 2>&1; then
    echo "$lockFile is not a JSON object, so it is not a clojure-cli-purifier lockfile; run clojure-cli-purifier lock --force"
    return
  fi
  if [ "$(jq -r .version "$lockFile")" != "$PURIFIER_FORMAT" ]; then
    echo "$lockFile has lock format version $(jq -r .version "$lockFile"), and this clojure-cli-purifier reads version $PURIFIER_FORMAT; run clojure-cli-purifier lock --force"
    return
  fi
  if [ "$(jq -r .contentHash "$lockFile")" != "$(contentHash "$lockFile")" ]; then
    echo "$lockFile does not match its contentHash, so it was edited after the lock run; run clojure-cli-purifier lock --force"
    return
  fi
  sourceRoot=$(sourceRootOf "$root" "$(lockProjectDir "$lockFile")")
  mapfile -t files < <(jq -r '.definitionFiles[]' "$lockFile")
  if [ "$(jq -r .definitionHash "$lockFile")" != "$(definitionHash "$sourceRoot" "${files[@]}")" ]; then
    echo "the project definition in $sourceRoot ($(jq -r '.definitionFiles | join(", ")' "$lockFile")) changed after $lockFile was made; run clojure-cli-purifier lock"
    return
  fi
  if [ "$(jq -r .clojureVersion "$lockFile")" != "$(clojureVersion)" ]; then
    echo "$lockFile was made with Clojure CLI $(jq -r .clojureVersion "$lockFile"), and this clojure-cli-purifier runs Clojure CLI $(clojureVersion); run clojure-cli-purifier lock"
  fi
}

lockIsCurrent() {
  [ -z "$(lockProblem "$1" "$2")" ]
}

# Preserve the caller's -Sdeps and execution mode while activating the
# selected coordinates for CLI resolution. Independent bases use private
# repository aliases prepared below.
clojure() {
  if [ -z "${PURIFIER_PROVIDED_CONFIG:-}" ]; then command clojure "$@"; return; fi
  local supplied='' mode=0 configuration
  local arguments=()
  while [ $# -gt 0 ]; do
    case $1 in
    -Sdeps)
      [ $# -ge 2 ] || die "-Sdeps needs an EDN map"
      supplied=$2; shift 2 ;;
    -T?*)
      if [[ $1 == -T:* ]]; then
        arguments+=("$1:nix-purifier-project-inputs")
      else
        # -Ttool names an installed tool, rather than project aliases.
        # Its independent basis reads the prepared private Maven aliases.
        arguments+=("$1")
      fi
      shift
      arguments+=("$@")
      mode=1
      break ;;
    -M* | -X* | -T | -A*)
      arguments+=("$1:nix-purifier-project-inputs")
      shift
      arguments+=("$@")
      mode=1
      break ;;
    *) arguments+=("$1"); shift ;;
    esac
  done
  if [ "$mode" = 0 ]; then arguments=(-A:nix-purifier-project-inputs "${arguments[@]}"); fi
  configuration=$(helper merge-input-config "$PURIFIER_PROVIDED_CONFIG" "$supplied")
  command clojure -Sdeps "$configuration" "${arguments[@]}"
}

stageInputAliases() {
  local repository=$1 metadata=$2
  shift 2
  local definitions=()
  mapfile -t definitions < <(find "$@" \( -name target -o -name .git -o -name _repos -o -name .cpcache -o -name .clojure-cli-purifier \) -prune \
    -o -type f -name deps.edn -print)
  helper mvn-requests "${definitions[@]}" > "$metadata/requests.tsv"
  python3 "$PURIFIER_LIB/maven-aliases.py" "$PURIFIER_PROJECT_INPUTS_TOOLS" \
    "$repository" "$metadata" "$metadata/requests.tsv"
}

cmdLock() {
  local force=0 userAliases="" source="" lockArg=""
  local -a builds=() tests=() aliases=() mirrorSpecs=() inputArgs=()
  while [ $# -gt 0 ]; do
    case $1 in
    --force) force=1 ;;
    --input)
      [ $# -ge 2 ] || die "lock: --input takes a flake package"
      inputArgs+=(--input "$2")
      force=1
      shift
      ;;
    --lockfile)
      [ $# -ge 2 ] || die "lock: --lockfile takes a path"
      lockArg=$2
      shift
      ;;
    --build)
      [ $# -ge 2 ] || die "lock: --build takes a command line"
      builds+=("$2")
      shift
      ;;
    --test)
      [ $# -ge 2 ] || die "lock: --test takes a command line"
      tests+=("$2")
      shift
      ;;
    --alias)
      [ $# -ge 2 ] || die "lock: --alias takes an alias"
      aliases+=("$2")
      shift
      ;;
    --user-aliases) userAliases=true ;;
    --no-user-aliases) userAliases=false ;;
    --mirror)
      if [ $# -lt 2 ] || [[ $2 != *=* ]]; then die "lock: --mirror takes ID=URL"; fi
      mirrorSpecs+=("$2")
      shift
      ;;
    --source)
      [ $# -ge 2 ] || die "lock: --source takes a directory"
      source=$2
      shift
      ;;
    *) die "lock: unknown argument $1" ;;
    esac
    shift
  done

  local root lockFile
  root=$(projectRoot)
  lockFile=$(lockFileOf "$root" "$lockArg")
  mkdir -p "$(dirname "$lockFile")"
  # A relock starts from a valid lockfile only.
  if [ -f "$lockFile" ] && ! jq -e 'type == "object"' "$lockFile" >/dev/null 2>&1; then
    [ $force = 1 ] || die "$lockFile is not a JSON object; run clojure-cli-purifier lock --force"
    rm "$lockFile"
  fi
  local explicit=0
  if [ ${#builds[@]} -gt 0 ] || [ ${#tests[@]} -gt 0 ] || [ ${#aliases[@]} -gt 0 ] || [ -n "$userAliases" ] || [ -n "$source" ]; then
    explicit=1
  fi

  # The source root holds the project and its local dependencies. A relock
  # without --source keeps the source root of the existing lockfile.
  local sourceRoot projectDir
  if [ -n "$source" ]; then
    sourceRoot=$(cd "$source" && pwd)
  elif [ -f "$lockFile" ]; then
    sourceRoot=$(sourceRootOf "$root" "$(lockProjectDir "$lockFile")")
  else
    sourceRoot=$root
  fi
  case $root in
  "$sourceRoot") projectDir=. ;;
  "$sourceRoot"/*) projectDir=${root#"$sourceRoot/"} ;;
  *) die "lock: the project $root is not inside the source root $sourceRoot" ;;
  esac
  if [ $force = 0 ] && [ $explicit = 0 ] && lockIsCurrent "$root" "$lockFile"; then
    echo "clojure-cli-purifier: $lockFile is up to date"
    return
  fi

  # Each option replaces its part of the existing lockfile, and a part no
  # option names keeps its value from the lockfile.
  local buildJson testJson aliasJson
  local hasLock=0
  if [ -f "$lockFile" ]; then hasLock=1; fi
  if [ ${#builds[@]} -gt 0 ]; then
    buildJson=$(commandsJson "${builds[@]}")
  elif [ $hasLock = 1 ]; then
    buildJson=$(jq -c .build "$lockFile")
  else
    # The default build runs build.clj through the :build alias of deps.edn.
    # A project whose build.clj runs under babashka has no :build alias.
    if [ -f "$root/build.clj" ] && helper aliases "$root/deps.edn" | grep -qx ':build'; then
      if grep -q '(defn uber\b' "$root/build.clj"; then
        builds=("-T:build uber")
      elif grep -q '(defn jar\b' "$root/build.clj"; then
        builds=("-T:build jar")
      fi
    fi
    buildJson=$(commandsJson "${builds[@]}")
  fi
  if [ ${#tests[@]} -gt 0 ]; then
    testJson=$(commandsJson "${tests[@]}")
  elif [ $hasLock = 1 ]; then
    testJson=$(jq -c .test "$lockFile")
  else
    testJson='[]'
  fi
  if [ ${#aliases[@]} -gt 0 ]; then
    aliasJson=$(printf '%s\n' "${aliases[@]}" | jq -R . | jq -sc .)
  elif [ $hasLock = 1 ]; then
    aliasJson=$(jq -c .aliases "$lockFile")
  else
    aliasJson=null
  fi
  if [ -z "$userAliases" ]; then
    if [ $hasLock = 1 ]; then userAliases=$(jq -r .userAliases "$lockFile"); else userAliases=false; fi
  fi

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/clojure-cli-purifier.XXXXXX")
  # Git names the repository of a checkout by its physical path, which the
  # lock run matches against the gitlibs directory below. On macOS the
  # temporary directory lies behind the /var symlink.
  work=$(cd "$work" && pwd -P)
  # shellcheck disable=SC2064 # work is fixed from here on
  trap "chmod -R u+w '$work' 2>/dev/null; rm -rf '$work'" EXIT
  mkdir -p "$work/source" "$work/home" "$work/config" "$work/cache" "$work/gitlibs" "$work/java-tmp"
  tar -C "$sourceRoot" --exclude=target --exclude=.cpcache --exclude=.clojure-cli-purifier --exclude=.git -cf - . | tar -C "$work/source" -xf -
  local project="$work/source"
  if [ "$projectDir" != . ]; then project="$work/source/$projectDir"; fi

  # The lock run sees what a sandboxed build sees: an empty local
  # repository, an empty gitlibs directory and no user configuration. The
  # JVMs take their local repository from user.home, which HOME does not
  # set.
  local realHome=$HOME userConfig
  userConfig="${CLJ_CONFIG:-${XDG_CONFIG_HOME:-$realHome/.config}/clojure}"
  if [ -z "${CLJ_CONFIG:-}" ] && [ ! -d "$userConfig" ]; then userConfig="$realHome/.clojure"; fi
  writeSettings "$work/home/.m2" "$realHome"
  addMirrors "$work/home/.m2/settings.xml" "${mirrorSpecs[@]}"
  # A lock keeps the versions the lockfile resolved its version ranges and
  # SNAPSHOTs to, from the metadata it recorded. `update` leaves out the
  # metadata of the libraries it updates.
  if [ $hasLock = 1 ] && [ "$updateAll" = 0 ]; then
    mkdir -p "$work/home/.m2/repository"
    seedMetadata "$lockFile" "$work/home/.m2/repository" "$work/home/.m2/settings.xml" "${updatePrefixes[@]}"
  fi
  local previousArgs=() refreshArgs=()
  if [ "$hasLock" = 1 ]; then previousArgs=(--previous "$lockFile"); fi
  if [ "$updateAll" = 1 ]; then refreshArgs=(--refresh); fi
  python3 "$PURIFIER_PROJECT_INPUTS_TOOLS/project_inputs.py" pin "${previousArgs[@]}" \
    "${inputArgs[@]}" "${refreshArgs[@]}" --output "$work/inputs.json"
  if [ "$(jq length "$work/inputs.json")" -gt 0 ]; then
    python3 "$PURIFIER_PROJECT_INPUTS_TOOLS/project_inputs.py" maven --inputs "$work/inputs.json" \
      --destination "$work/home/.m2/repository" --metadata "$work/input-metadata" --roots "$work/inputs"
    export PURIFIER_PROVIDED_CONFIG="$work/input-metadata/project-inputs.edn"
    stageInputAliases "$work/home/.m2/repository" "$work/input-metadata" "$work/source" "$work/gitlibs"
  fi
  echo '{}' >"$work/config/deps.edn"
  export HOME="$work/home"
  export CLJ_CONFIG="$work/config"
  export CLJ_CACHE="$work/cache"
  export GITLIBS="$work/gitlibs"
  export CLJ_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$work/java-tmp"
  export JAVA_OPTS="$CLJ_JVM_OPTS"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  local m2="$work/home/.m2/repository"

  # The aliases to prepare: the given ones, or every alias of the project.
  local -a prepare
  if [ "$aliasJson" = null ]; then
    mapfile -t prepare < <(helper aliases "$project/deps.edn")
  else
    mapfile -t prepare < <(jq -r '.[]' <<<"$aliasJson")
  fi
  local -a userPrepare=()
  if [ "$userAliases" = true ] && [ -f "$userConfig/deps.edn" ]; then
    mapfile -t userPrepare < <(helper aliases "$userConfig/deps.edn")
  fi

  echo "clojure-cli-purifier: locking $root"
  # Each step runs in a subshell whose output goes to the log, and the
  # caller tests its status with ||, which turns off errexit inside it. So
  # every command in a step exits the step itself when it fails.
  local alias log="$work/log"
  : >"$log"
  # Runs the Clojure CLI to resolve and download. A git dependency that
  # needs preparing stops the CLI with "must be prepared before use" once
  # it has resolved the project and cloned the dependency. That is no
  # failure of the first pass, which has to record the checkouts before
  # they are prepared. It makes the lock run resolve once more after the
  # preparation.
  resolveWith() {
    local output status=0
    output=$(clojure "$@" 2>&1) || status=$?
    printf '%s\n' "$output"
    if [ $status != 0 ]; then
      if grep -q 'must be prepared before use' <<<"$output"; then
        touch "$work/needs-prep"
      else
        return 1
      fi
    fi
  }
  # A POM can choose dependencies by architecture, through a profile that
  # Maven Resolver activates from os.arch. The project resolves again for
  # each architecture the flake builds for, so the lock holds what every
  # one of them resolves.
  local thisArch
  thisArch=$("$JAVA_CMD" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *os.arch = //p')
  resolveProject() {
    local otherArch archOpts
    (
      cd "$project" || exit 1
      resolveWith -P || exit 1
      for alias in "${prepare[@]}"; do
        resolveWith -P "-M$alias" || exit 1
      done
    ) 2>&1 | tee -a "$log" || die "preparing the project failed; see the output above"
    for otherArch in amd64 aarch64; do
      [ "$otherArch" != "$thisArch" ] || continue
      archOpts="$CLJ_JVM_OPTS -Dos.arch=$otherArch"
      (
        cd "$project" || exit 1
        CLJ_JVM_OPTS=$archOpts resolveWith -Sforce -P || exit 1
        for alias in "${prepare[@]}"; do
          CLJ_JVM_OPTS=$archOpts resolveWith -Sforce -P "-M$alias" || exit 1
        done
      ) 2>&1 | tee -a "$log" || die "preparing the project for $otherArch failed; see the output above"
    done
  }
  resolveProject
  if [ ${#userPrepare[@]} -gt 0 ]; then
    # The aliases of the user deps.edn resolve with it, in a cache of their
    # own.
    (
      cd "$project" || exit 1
      export CLJ_CONFIG="$work/user-config"
      mkdir -p "$CLJ_CONFIG"
      cp "$userConfig/deps.edn" "$CLJ_CONFIG/deps.edn"
      for alias in "${userPrepare[@]}"; do
        CLJ_CACHE="$work/user-cache" clojure -Sforce -P "-M$alias" || exit 1
      done
    ) 2>&1 | tee -a "$log" || die "preparing the user aliases failed; see the output above"
  fi

  # The git dependencies, before preparing them changes their checkouts.
  local gitEntries="$work/git.jsonl" gitRepos="$work/repos.jsonl"
  : >"$gitEntries"
  : >"$gitRepos"
  local bare url checkout rev rel copy hash tree index="$work/index"
  local -a revs commits parents
  while IFS= read -r bare; do
    url=$(git --git-dir="$bare" config remote.origin.url)
    revs=()
    for checkout in "$GITLIBS"/libs/*/*/*; do
      [ -f "$checkout/.git" ] || continue
      case $(sed -n 's/^gitdir: //p' "$checkout/.git") in
      "$bare"/*) ;;
      *) continue ;;
      esac
      rev=$(basename "$checkout")
      revs+=("$rev")
      rel=${checkout#"$GITLIBS/"}
      copy="$work/checkout"
      rm -rf "$copy"
      mkdir -p "$copy"
      tar -C "$checkout" --exclude=./.git -cf - . | tar -C "$copy" -xf -
      hash=$(nix-hash --type sha256 --sri "$copy")
      # The Nix build rebuilds the commit from the files of the checkout,
      # so the files must give the tree of the commit.
      tree=$(GIT_INDEX_FILE="$index" git --git-dir="$bare" --work-tree="$copy" -c core.autocrlf=false add --all --force . &&
        GIT_INDEX_FILE="$index" git --git-dir="$bare" write-tree)
      rm -f "$index"
      if [ "$tree" != "$(git --git-dir="$bare" rev-parse "$rev^{tree}")" ]; then
        die "the checkout of $url at $rev does not give the tree of its commit, so the Nix build could not rebuild the commit"
      fi
      jq -cn --arg path "$rel" --arg url "$url" --arg rev "$rev" --arg hash "$hash" \
        '{ path: $path, git: { url: $url, rev: $rev, submodules: false, leaveDotGit: false, commitObject: null }, hash: $hash }' >>"$gitEntries"
    done
    [ ${#revs[@]} -gt 0 ] || continue
    # The commits the Clojure CLI may read: the locked ones, and when one
    # repository has several, every commit between them and their merge
    # base, which an ancestry check walks. A commit with a parent outside
    # that set is a shallow boundary.
    if [ ${#revs[@]} = 1 ]; then
      commits=("${revs[0]}")
    else
      local base
      base=$(git --git-dir="$bare" merge-base --octopus "${revs[@]}")
      mapfile -t parents < <(git --git-dir="$bare" rev-parse "$base^@")
      mapfile -t commits < <(git --git-dir="$bare" rev-list "${revs[@]}" --not "${parents[@]}")
    fi
    local commitJson shallowJson tagJson c p
    commitJson=$(for c in "${commits[@]}"; do
      git --git-dir="$bare" cat-file commit "$c" | jq -Rs --arg sha "$c" '{ sha: $sha, object: . }'
    done | jq -sc .)
    shallowJson=$(for c in "${commits[@]}"; do
      read -ra parents < <(git --git-dir="$bare" rev-list --parents -n1 "$c" | cut -s -d' ' -f2-)
      if [ ${#parents[@]} = 0 ]; then
        continue
      fi
      for p in "${parents[@]}"; do
        if ! printf '%s\n' "${commits[@]}" | grep -qx "$p"; then
          echo "$c"
          break
        fi
      done
    done | LC_ALL=C sort -u | jq -R . | jq -sc .)
    tagJson=$(for c in "${revs[@]}"; do
      git --git-dir="$bare" tag --points-at "$c" | jq -R --arg rev "$c" '{ key: ., value: $rev }'
    done | jq -sc 'from_entries')
    jq -cn --arg path "${bare#"$GITLIBS/"}" --arg url "$url" \
      --argjson commits "$commitJson" --argjson shallow "$shallowJson" --argjson tags "$tagJson" \
      '{ path: $path, url: $url, commits: $commits, shallow: $shallow, tags: $tags }' >>"$gitRepos"
  done < <(find "$GITLIBS/_repos" -name HEAD -not -path '*/worktrees/*' -printf '%h\n' 2>/dev/null | LC_ALL=C sort)

  if [ -n "${PURIFIER_PROVIDED_CONFIG:-}" ]; then
    stageInputAliases "$m2" "$work/input-metadata" "$work/source" "$GITLIBS"
  fi

  # Git dependencies that need preparing, then the build and its tests.
  local stamp="$work/stamp"
  touch "$stamp"
  sleep 1
  (
    cd "$project" || exit 1
    clojure -X:deps prep :aliases "[${prepare[*]}]" || exit 1
  ) 2>&1 | tee -a "$log" || die "preparing the git dependencies failed; see the output above"
  # The passes that the missing preparation cut short run again.
  if [ -f "$work/needs-prep" ]; then
    resolveProject
  fi
  (
    cd "$project" || exit 1
    while IFS= read -r command; do
      mapfile -t words < <(jq -r '.[]' <<<"$command")
      echo "clojure-cli-purifier: clojure ${words[*]}"
      clojure "${words[@]}" || exit 1
    done < <(jq -c '.[]' <<<"$buildJson" && jq -c '.[]' <<<"$testJson")
  ) 2>&1 | tee -a "$log" || die "the build failed; see the output above"

  # The outputs: the jars the build commands created.
  local outputs="$work/outputs.jsonl" output mainClass
  : >"$outputs"
  while IFS= read -r output; do
    mainClass=$(unzip -p "$project/$output" META-INF/MANIFEST.MF 2>/dev/null |
      tr -d '\r' | sed -n 's/^Main-Class: *//p' | jq -R . | jq -s 'first // null')
    jq -cn --arg path "$output" --argjson mainClass "$mainClass" '{ path: $path, mainClass: $mainClass }' >>"$outputs"
  done < <(cd "$project" && find . \( -name .cpcache -o -name classes \) -prune -o \
    \( -name '*.jar' -o -name '*.war' \) -type f -newer "$stamp" -printf '%P\n' | LC_ALL=C sort)

  # The project: from the POM the build wrote, or the directory name.
  local pom=null group="" name version=null pomPath pomFile
  name=$(basename "$root")
  pomPath=$(cd "$project" && find . -name .cpcache -prune -o -name pom.xml -type f -newer "$stamp" -printf '%P\n' | LC_ALL=C sort | head -1)
  if [ -n "$pomPath" ]; then
    pom=$(jq -n --arg p "$pomPath" '$p')
    pomFile="$project/$pomPath"
    pomField() {
      awk -v tag="$1" '
        /<parent>/ { p = 1 }
        /<\/parent>/ { p = 0; next }
        !p && index($0, "<" tag ">") { gsub(".*<" tag ">|</" tag ">.*", ""); print; exit }
      ' "$pomFile"
    }
    group=$(pomField groupId)
    name=$(pomField artifactId)
    version=$(pomField version | jq -R . | jq -s 'first // null')
  fi

  # The repositories the downloads came from, by the id Maven Resolver
  # records: those of every basis the Clojure CLI wrote, and the mirrors of
  # settings.xml.
  declare -A repositoryUrl mirrorOf
  local id of
  while IFS=$'\t' read -r id url of; do
    if [[ $url != */ ]]; then url="$url/"; fi
    repositoryUrl[$id]=$url
    if [ -n "$of" ]; then mirrorOf[$id]=$of; fi
  done < <(
    mapfile -t bases < <(find "$project/.cpcache" "$work/cache" "$work/user-cache" -name '*.basis' 2>/dev/null)
    if [ ${#bases[@]} -gt 0 ]; then helper repos "${bases[@]}"; fi
    mirrors "$work/home/.m2/settings.xml"
  )

  # Every file in the local repository is a download, except the records
  # Maven Resolver keeps. Version lists change on the server, so they are
  # kept with their contents. The rest is named in the _remote.repositories
  # file of its directory, with the id of the repository it came from.
  local artifacts="$work/artifacts.jsonl" metadata="$work/metadata.jsonl"
  local -a untracked=() unknown=()
  : >"$artifacts"
  : >"$metadata"
  # The resolver names the version list of a repository after its id. The
  # build resolves without the mirrors of the lock run, so a version list a
  # mirror of one repository served takes the id of that repository.
  local -a renames=(-e 's/^/&/')
  local mirrorId
  for mirrorId in "${!mirrorOf[@]}"; do
    if [ -n "${repositoryUrl[${mirrorOf[$mirrorId]}]:-}" ]; then
      renames+=(-e "s/maven-metadata-$mirrorId\\.xml/maven-metadata-${mirrorOf[$mirrorId]}.xml/g")
    fi
  done
  local dir name2 remote
  declare -A providedPaths=()
  if [ -f "$work/input-metadata/supplied-paths.json" ]; then
    while IFS= read -r rel; do providedPaths[$rel]=1; done < <(jq -r '.[]' "$work/input-metadata/supplied-paths.json")
  fi
  while IFS= read -r rel; do
    if [ -n "${providedPaths[$rel]:-}" ]; then continue; fi
    dir=$(dirname "$rel")
    name2=$(basename "$rel")
    case $name2 in
    _remote.repositories | *.lastUpdated | *.sha1 | *.md5 | *.sha256 | *.sha512)
      continue
      ;;
    maven-metadata*.xml)
      jq -cn --arg path "$dir/$(sed "${renames[@]}" <<<"$name2")" --rawfile contents "$m2/$rel" \
        '{ path: $path, contents: $contents }' >>"$metadata"
      continue
      ;;
    resolver-status.properties)
      # The resolver checks a version list again a day after the time it
      # records, so the time becomes the year 2100. The comment lines hold
      # the date of the lock run, which a relock would change.
      jq -cn --arg path "$rel" \
        --arg contents "$(sed -E "${renames[@]}" -e '/^#/d' -e 's/=[0-9]{13}$/=4102444800000/' "$m2/$rel")"$'\n' \
        '{ path: $path, contents: $contents }' >>"$metadata"
      continue
      ;;
    esac
    remote=$name2
    id=$(remoteId "$m2/$dir" "$name2")
    # Maven Resolver downloads a SNAPSHOT file under its timestamped name,
    # which it tracks, and keeps an untracked copy under the -SNAPSHOT
    # name. The copy comes from the same URL as the timestamped file the
    # metadata of its repository names.
    if [ -z "$id" ] && [[ $dir == *-SNAPSHOT && $name2 == *-SNAPSHOT* ]]; then
      local metadataFile candidate
      for metadataFile in "$m2/$dir"/maven-metadata-*.xml; do
        [ -f "$metadataFile" ] || continue
        candidate=$(helper snapshot-name "$metadataFile" "$name2")
        id=$(remoteId "$m2/$dir" "$candidate")
        if [ -n "$id" ]; then
          remote=$candidate
          break
        fi
      done
    fi
    if [ -z "$id" ]; then
      untracked+=("$rel")
      continue
    fi
    if [ -z "${repositoryUrl[$id]:-}" ]; then
      unknown+=("$rel (repository $id)")
      continue
    fi
    # A file is locked at the URL of its repository. When a mirror of that
    # one repository served it, the repository is the one the mirror
    # serves. Every mirror of the repository is a fallback, whichever of
    # them Maven Resolver recorded.
    local canonical=$id
    of=${mirrorOf[$id]:-}
    if [ -n "$of" ] && [ -n "${repositoryUrl[$of]:-}" ]; then canonical=$of; fi
    url="${repositoryUrl[$canonical]}$dir/$remote"
    local -a fallbacks=()
    for mirrorId in "${!mirrorOf[@]}"; do
      if [ "${mirrorOf[$mirrorId]}" = "$canonical" ]; then
        fallbacks+=("${repositoryUrl[$mirrorId]}$dir/$remote")
      fi
    done
    jq -cn --arg path "$rel" --arg url "$url" \
      --argjson mirrors "$(printf '%s\n' "${fallbacks[@]}" | grep -v '^$' | LC_ALL=C sort | jq -R . | jq -sc .)" \
      --arg hash "$(nix-hash --type sha256 --flat --sri "$m2/$rel")" \
      '{ path: $path, url: $url, mirrors: $mirrors, hash: $hash }' >>"$artifacts"
  done < <(cd "$m2" && find . -type f -printf '%P\n' | LC_ALL=C sort)

  if [ ${#untracked[@]} -gt 0 ]; then
    printf '  %s\n' "${untracked[@]}" >&2
    die "Maven Resolver recorded no repository for the files above"
  fi
  if [ ${#unknown[@]} -gt 0 ]; then
    printf '  %s\n' "${unknown[@]}" >&2
    die "the files above came from repositories that neither the project nor settings.xml names"
  fi
  # The lockfile keeps the metadata of the directories its files lie in:
  # the version list of a library whose version a range chose, and the
  # list of a SNAPSHOT. Metadata a relock seeded for a library the project
  # no longer resolves is left out.
  jq -c --slurpfile artifacts "$artifacts" \
    '(.path | split("/") | .[:-1] | join("/") + "/") as $dir
     | select(any($artifacts[]; .path | startswith($dir)))' "$metadata" >"$metadata.used"
  mv "$metadata.used" "$metadata"

  local -a files
  mapfile -t files < <(definitionFiles "$sourceRoot" "$projectDir")
  jq -n \
    --argjson version "$PURIFIER_FORMAT" \
    --slurpfile projectInputs "$work/inputs.json" \
    --arg clojureVersion "$(clojureVersion)" \
    --arg javaVersion "$(javaVersion)" \
    --arg projectDir "$projectDir" \
    --argjson definitionFiles "$(printf '%s\n' "${files[@]}" | jq -R . | jq -sc .)" \
    --arg definitionHash "$(definitionHash "$sourceRoot" "${files[@]}")" \
    --argjson aliases "$aliasJson" \
    --argjson prepared "$(printf '%s\n' "${prepare[@]}" | grep -v '^$' | jq -R . | jq -sc .)" \
    --argjson userAliases "$userAliases" \
    --argjson build "$buildJson" \
    --argjson test "$testJson" \
    --arg group "$group" --arg name "$name" --argjson projectVersion "$version" \
    --argjson pom "$pom" \
    --slurpfile outputs "$outputs" \
    --slurpfile artifacts "$artifacts" \
    --slurpfile metadata "$metadata" \
    --slurpfile git "$gitEntries" \
    --slurpfile gitRepos "$gitRepos" \
    '{
      version: $version,
      clojureVersion: $clojureVersion,
      javaVersion: $javaVersion,
      projectDir: $projectDir,
      definitionFiles: $definitionFiles,
      definitionHash: $definitionHash,
      aliases: $aliases,
      prepared: $prepared,
      userAliases: $userAliases,
      build: $build,
      test: $test,
      project: { group: $group, name: $name, version: $projectVersion },
      pom: $pom,
      outputs: $outputs,
      artifacts: $artifacts,
      metadata: $metadata,
      git: $git,
      gitRepos: $gitRepos
    } | if ($projectInputs[0] | length) > 0 then . + {projectInputs: $projectInputs[0]} else . end' >"$lockFile.content"
  jq --arg contentHash "$(contentHash "$lockFile.content")" '. + { contentHash: $contentHash }' \
    "$lockFile.content" >"$lockFile.tmp"
  rm "$lockFile.content"
  mv "$lockFile.tmp" "$lockFile"
  echo "clojure-cli-purifier: wrote $lockFile ($(jq '.artifacts | length' "$lockFile") files, $(jq '.git | length' "$lockFile") git checkouts, $(jq '.outputs | length' "$lockFile") outputs)"
}

# `update [LIB...]`: a relock that resolves the version ranges and SNAPSHOTs
# of every library, or of the named ones, anew. A library is named as in
# deps.edn, such as org.clojure/core.memoize.
cmdUpdate() {
  local -a lockArgs=(--force) libs=()
  while [ $# -gt 0 ]; do
    case $1 in
    --lockfile | --mirror | --input)
      [ $# -ge 2 ] || die "update: $1 takes a value"
      lockArgs+=("$1" "$2")
      shift
      ;;
    -*) die "update: unknown argument $1" ;;
    *) libs+=("$1") ;;
    esac
    shift
  done
  if [ ${#libs[@]} = 0 ]; then
    updateAll=1
  else
    local lib group artifact
    for lib in "${libs[@]}"; do
      if [[ $lib == */* ]]; then
        group=${lib%%/*} artifact=${lib#*/}
      else
        group=$lib artifact=$lib
      fi
      updatePrefixes+=("${group//.//}/$artifact/")
    done
  fi
  cmdLock "${lockArgs[@]}"
}

# The state directory of a lockfile: .clojure-cli-purifier beside it. It
# holds the GC root `env`, the writable local repository under `home`, the
# gitlibs directory `gitlibs`, the path of the lockfile in `lockfile`, and
# `bin/clojure`, which runs the Clojure CLI on the locked downloads.
stateOf() {
  echo "$(dirname "$1")/.clojure-cli-purifier"
}

cmdPrefetch() {
  local lockArg=""
  while [ $# -gt 0 ]; do
    case $1 in
    --lockfile)
      [ $# -ge 2 ] || die "prefetch: --lockfile takes a path"
      lockArg=$2
      shift
      ;;
    *) die "prefetch: unknown argument $1" ;;
    esac
    shift
  done

  local root lockFile problem
  root=$(projectRoot)
  lockFile=$(lockFileOf "$root" "$lockArg")
  problem=$(lockProblem "$root" "$lockFile")
  [ -z "$problem" ] || die "$problem"

  # nix-build keeps the environment alive with an indirect GC root at
  # state/env.
  local state env
  state=$(stateOf "$lockFile")
  mkdir -p "$state/bin"
  local projectDir
  projectDir=$(lockProjectDir "$lockFile")
  nix-build "$PURIFIER_LIB/realize.nix" --argstr lockFile "$lockFile" \
    --argstr src "$(sourceRootOf "$root" "$projectDir")" --argstr projectDir "$projectDir" \
    --argstr nixpkgs "$PURIFIER_NIXPKGS" --argstr purifierRef "$PURIFIER_SHARED_REF" \
    -o "$state/env" >/dev/null
  env=$(readlink -f "$state/env")

  # The local repository is a writable tree of links into the store, and
  # the gitlibs directory holds writable copies of the checkouts, which a
  # git dependency that needs preparing writes into.
  local home="$state/home" gitlibs="$state/gitlibs"
  chmod -R u+w "$home" "$gitlibs" 2>/dev/null || true
  rm -rf "$home" "$gitlibs" "$state/cache"
  mkdir -p "$home/.m2/repository" "$gitlibs"
  cp -rs --no-preserve=mode "$env/repository/." "$home/.m2/repository"
  # Maven Resolver rewrites the metadata records it reads, so those are
  # writable copies.
  find "$home/.m2/repository" -type l \( -name 'maven-metadata*.xml' -o -name resolver-status.properties \) \
    -exec cp --no-preserve=mode -L {} {}.tmp \; -exec mv {}.tmp {} \;
  cp -rL --no-preserve=mode "$env/gitlibs/." "$gitlibs"
  if [ "$(jq '.projectInputs // [] | length' "$lockFile")" -gt 0 ]; then
    jq '.projectInputs' "$lockFile" > "$state/inputs.json"
    rm -rf "$state/input-metadata"
    python3 "$PURIFIER_PROJECT_INPUTS_TOOLS/project_inputs.py" maven --inputs "$state/inputs.json" \
      --destination "$home/.m2/repository" --metadata "$state/input-metadata" --roots "$state/inputs"
    stageInputAliases "$home/.m2/repository" "$state/input-metadata" \
      "$(sourceRootOf "$root" "$projectDir")" "$gitlibs"
  fi
  echo "$lockFile" >"$state/lockfile"
  jq -r .contentHash "$lockFile" >"$state/prefetched"
  ln -sfn "$(readlink -f "$0")" "$state/bin/clojure"

  # The git dependencies that need preparing are prepared now, as the Nix
  # build prepares them.
  "$state/bin/clojure" -X:deps prep :aliases "[$(jq -r '.prepared | join(" ")' "$lockFile")]" >/dev/null
  echo "clojure-cli-purifier: prefetched $(jq '.artifacts | length' "$lockFile") files and $(jq '.git | length' "$lockFile") git checkouts for $root"
  echo "clojure-cli-purifier: put $state/bin first on PATH, and \`clojure\` runs on them with no network"
}

# `clojure` in the state directory of a lockfile: the Clojure CLI, with the
# prefetched local repository and gitlibs directory in place of those in the
# home directory.
runClojure() {
  local state lockFile root problem
  state=$(cd "$(dirname "$0")/.." && pwd)
  [ -f "$state/lockfile" ] || die "$state holds no prefetch; run clojure-cli-purifier prefetch"
  lockFile=$(cat "$state/lockfile")
  if [ ! -e "$lockFile" ]; then
    echo "clojure-cli-purifier: warning: no clojure-cli-purifier.lock.json found; running clojure impurely. Run \`clojure-cli-purifier lock\` to use Nix-resolved dependencies." >&2
    exec clojure "$@"
  fi
  root=$(projectRoot)
  problem=$(lockProblem "$root" "$lockFile")
  [ -z "$problem" ] || die "$problem"
  [ "$(cat "$state/prefetched")" = "$(jq -r .contentHash "$lockFile")" ] ||
    die "$lockFile changed after the last prefetch; run clojure-cli-purifier prefetch"

  # The JVMs find the local repository through user.home. The Clojure CLI
  # configuration of the user stays in effect. Git trusts the checkouts,
  # which the store owns.
  export GITLIBS="$state/gitlibs"
  export CLJ_CACHE="$state/cache"
  export CLJ_JVM_OPTS="-Duser.home=$state/home ${CLJ_JVM_OPTS:-}"
  export JAVA_OPTS="-Duser.home=$state/home ${JAVA_OPTS:-}"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

  if [ "$(jq '.projectInputs // [] | length' "$lockFile")" -gt 0 ]; then
    export PURIFIER_PROVIDED_CONFIG="$state/input-metadata/project-inputs.edn"
  fi

  # The standard error of the Clojure CLI also goes to a log. When it fails
  # to resolve a download, the lockfile lacks that download.
  local log status=0
  log=$(mktemp "${TMPDIR:-/tmp}/clojure-cli-purifier-clojure.XXXXXX")
  clojure "$@" 2> >(tee "$log" >&2) || status=$?
  wait
  if [ $status != 0 ] && grep -qE 'could not be resolved|Could not transfer|Could not find artifact|Failed to read artifact descriptor|Unable to clone|Network is unreachable' "$log"; then
    echo "clojure-cli-purifier: the Clojure CLI tried to download something $lockFile does not hold; run clojure-cli-purifier lock, then clojure-cli-purifier prefetch" >&2
  fi
  rm -f "$log"
  return $status
}

cmdPublish() {
  local repository="" dryRun=0 lockArg=""
  while [ $# -gt 0 ]; do
    case $1 in
    --lockfile)
      [ $# -ge 2 ] || die "publish: --lockfile takes a path"
      lockArg=$2
      shift
      ;;
    --repository)
      [ $# -ge 2 ] || die "publish: --repository takes ID=URL"
      repository=$2
      shift
      ;;
    --dry-run) dryRun=1 ;;
    *) die "publish: unknown argument $1" ;;
    esac
    shift
  done

  local root lockFile problem
  root=$(projectRoot)
  lockFile=$(lockFileOf "$root" "$lockArg")
  problem=$(lockProblem "$root" "$lockFile")
  [ -z "$problem" ] || die "$problem"
  [ "$(jq -r .pom "$lockFile")" != null ] || die "the build of the lock writes no POM, which publishing needs"

  local projectDir release state
  projectDir=$(lockProjectDir "$lockFile")
  state=$(stateOf "$lockFile")
  mkdir -p "$state"
  release=$(nix-build --out-link "$state/release" "$PURIFIER_LIB/release.nix" \
    --argstr nixpkgs "$PURIFIER_NIXPKGS" --argstr purifierRef "$PURIFIER_SHARED_REF" \
    --argstr src "$(sourceRootOf "$root" "$projectDir")" --argstr projectDir "$projectDir" \
    --argstr lockFile "$lockFile")
  [ -n "$PURIFIER_DEPLOY_CLASSPATH" ] || \
    die "this clojure-cli-purifier was built without its deploy tool lockfile"
  "$JAVA_CMD" -cp "$(cat "$PURIFIER_DEPLOY_CLASSPATH")" clojure.main \
    "$PURIFIER_LIB/deploy-projections.clj" "$release/repository" "$release/catalog.json" "$repository" "$dryRun"
}

# Linked as bin/clojure in a state directory, this script is the Clojure
# CLI on the prefetched downloads.
if [ "$(basename "$0")" = clojure ]; then
  runClojure "$@"
  exit
fi

case ${1:-} in
lock)
  shift
  cmdLock "$@"
  ;;
update)
  shift
  cmdUpdate "$@"
  ;;
prefetch)
  shift
  cmdPrefetch "$@"
  ;;
publish)
  shift
  cmdPublish "$@"
  ;;
-h | --help | help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
