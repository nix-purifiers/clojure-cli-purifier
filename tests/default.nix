# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked files and checkouts. The
# check `conformance-relock` of the purifier contract needs the network for
# its lock runs, so it is a job of CI (.github/workflows/check.yml).
{
  pkgs,
  # The default package overlay of the flake, which adds the builder
  # `buildClojureCliProject`.
  overlay,
  # The lockfile reader, `readLock` in the `lib.clojure-cli-purifier` of the
  # flake.
  readLock,
  # The clojure-cli-purifier command.
  cli,
}:
let
  inherit (pkgs) lib;
  # Every fixture builds the way a consumer's package does: through the
  # buildClojureCliProject of a package set that has the overlay.
  inherit ((pkgs.extend overlay).clojure-cli-purifier) buildClojureCliProject;
  build = buildClojureCliProject;

  # An application with dependencies from Maven Central and Clojars, a
  # local dependency, git dependencies given by tag and short commit
  # (tools.build and the test runner), a SNAPSHOT and a version range. Its
  # tests run in the build, among them the SNAPSHOT and the version range.
  hello = build { src = ./fixtures/hello; };
  helloLockPath = ./fixtures/hello/clojure-cli-purifier.lock.json;
  helloLock = builtins.fromJSON (builtins.readFile helloLockPath);

  # A lockfile with this content and a matching contentHash, as a lock run
  # would write it.
  lockFileOf =
    content:
    builtins.toFile "clojure-cli-purifier.lock.json" (
      builtins.toJSON (
        content
        // {
          contentHash = builtins.hashString "sha256" (
            builtins.toJSON (removeAttrs content [ "contentHash" ])
          );
        }
      )
    );
  # The hello lockfile with some fields changed, and its contentHash made
  # anew.
  helloLockWith = attrs: lockFileOf (helloLock // attrs);

  # Whether buildClojureCliProject refuses the hello project with this
  # lockfile when the package is evaluated.
  refuses =
    lockFile:
    !(builtins.tryEval
      (build {
        src = ./fixtures/hello;
        inherit lockFile;
      }).packages.hello.drvPath
    ).success;

  # Runs a command of clojure-cli-purifier on a copy of the hello project
  # with a lockfile, expects it to fail, and checks that its message names
  # the command that fixes the lockfile. `edit` changes the copy first.
  commandRefuses =
    name:
    {
      lockFile,
      edit ? "",
      expect,
    }:
    pkgs.runCommand name { nativeBuildInputs = [ cli ]; } ''
      export HOME="$TMPDIR/home"
      cp -r ${./fixtures/hello} hello
      chmod -R u+w hello
      cp ${lockFile} hello/clojure-cli-purifier.lock.json
      cd hello
      ${edit}
      if clojure-cli-purifier prefetch 2>"$TMPDIR/log"; then
        echo "prefetch accepted the lockfile" >&2
        exit 1
      fi
      cat "$TMPDIR/log"
      grep -q ${lib.escapeShellArg expect} "$TMPDIR/log"
      touch $out
    '';

  # A copy of the hello lock without the data.json jar, with a matching
  # contentHash, so it passes evaluation and the build misses the file.
  missingLock = helloLockWith {
    artifacts = builtins.filter (
      entry: entry.path != "org/clojure/data.json/2.5.1/data.json-2.5.1.jar"
    ) helloLock.artifacts;
  };

  # The environment of `clojure-cli-purifier prefetch`, as realize.nix
  # builds it, from the builder's repository and gitlibs directory.
  helloEnv = pkgs.runCommand "clojure-cli-purifier-env" { } ''
    mkdir -p $out
    ln -s ${hello.repository} $out/repository
    ln -s ${hello.gitlibs} $out/gitlibs
  '';

  # A nix-build for the sandbox, which links the prebuilt environment where
  # prefetch asks for its GC root.
  fakeNixBuild = pkgs.writeShellScriptBin "nix-build" ''
    while [ $# -gt 0 ]; do
      if [ "$1" = -o ]; then ln -sfn ${helloEnv} "$2"; fi
      shift
    done
  '';

  # honeysql at a fixed commit, fetched at evaluation time, so the builder
  # reads its deps.edn without import-from-derivation.
  honeysqlSrc = builtins.fetchTree {
    type = "github";
    owner = "seancorfield";
    repo = "honeysql";
    rev = "1cc6bbed923bacdffe8cf727ef044e924d2a3597";
    narHash = "sha256-ung2gdsJ3LdKJxK/eBwJqXNIr7JzK4DJ2enShl9XLE4=";
  };
in
{
  java-major =
    pkgs.runCommand "java-major"
      {
        nativeBuildInputs = [
          pkgs.nix
          pkgs.python3
        ];
      }
      ''
        python3 -B ${./java-major.py} ${../pkgs/build-clojure-cli-project/default.nix} ${pkgs.path}/lib
        touch $out
      '';

  jvm-projection = hello.packages.hello.projections.maven;

  composition = import ./composition.nix {
    inherit pkgs build;
    purifier = (pkgs.extend overlay).lib.purifier;
  };
  inherit cli;

  # The functions the lock run uses to read and write files, and the helper
  # it runs on the tools jar of the Clojure CLI.
  unit =
    pkgs.runCommand "unit"
      {
        nativeBuildInputs = with pkgs; [
          jq
          gawk
          gnugrep
          findutils
          coreutils
        ];
        LIB_SH = ../pkgs/clojure-cli-purifier/lib.sh;
        HELPER = ../pkgs/clojure-cli-purifier/helper.clj;
        TOOLS_JAR = "${cli.clojure}/libexec/clojure-tools-${cli.clojure.version}.jar";
        JAVA = "${cli.jdk}/bin/java";
      }
      ''
        bash ${./unit.sh}
        touch $out
      '';

  # readLock gives the lock in memory of the purifier contract. Its entries
  # have the shapes of the shared purifier library: file entries with
  # mirrors, inline metadata, and git entries without a .git directory.
  # `fetches` is the entries, and `outputs` names the package.
  lock-reader =
    let
      lock = readLock { src = ./fixtures/hello; };
      kind = key: builtins.filter (entry: entry ? ${key}) lock.entries;
    in
    assert lock.purifier == "clojure-cli-purifier";
    assert lock.problems == [ ];
    assert builtins.attrNames lock.outputs == [ "hello" ];
    assert lock.outputs.hello.mainClasses."target/hello-1.0.0-standalone.jar" == "hello.core";
    assert builtins.all (entry: entry ? mirrors && entry ? hash) (kind "url");
    assert builtins.length (kind "contents") == 4;
    assert builtins.length (kind "git") == 2;
    assert builtins.all (
      entry:
      entry.git.submodules == false && entry.git.leaveDotGit == false && entry.git.commitObject == null
    ) (kind "git");
    assert hello.fetches == lock.entries;
    # An unusable lockfile is a problem that names the fix, not a failure.
    assert
      builtins.match ".*clojure-cli-purifier lock --force.*" (
        builtins.head
          (readLock {
            src = ./fixtures/hello;
            lockFile = builtins.toFile "clojure-cli-purifier.lock.json" ''{ "version": 2, '';
          }).problems
      ) != null;
    pkgs.runCommand "lock-reader" { } "touch $out";

  hello = hello.packages.hello;
  hello-tests = hello.tests;

  # The launcher runs the uberjar, which holds every dependency and the
  # local one.
  hello-runs = pkgs.runCommand "hello-runs" { } ''
    ${hello.packages.hello}/bin/hello > output
    grep -qx '{"hello":"Hello, Nix"}' output
    grep -qx '<p>purified</p>' output
    touch $out
  '';

  # The release holds the jar and the POM that publish deploys.
  hello-release = pkgs.runCommand "hello-release" { } ''
    test -f ${hello.release}/hello-1.0.0.jar
    grep -q '<artifactId>hello</artifactId>' ${hello.release}/hello-1.0.0.pom
    touch $out
  '';

  # The rebuilt bare repositories hold the locked commits and their tags,
  # so the Clojure CLI expands a short commit and checks a tag offline.
  hello-gitlibs =
    pkgs.runCommand "hello-gitlibs"
      {
        nativeBuildInputs = [ pkgs.git ];
      }
      ''
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
        repo=${hello.gitlibs}/_repos/https/github.com/cognitect-labs/test-runner
        test "$(git --git-dir=$repo rev-parse dfb30dd^{commit})" = dfb30dd6605cb6c0efc275e1df1736f6e90d4d73
        test "$(git --git-dir=$repo rev-parse v0.5.1^{commit})" = dfb30dd6605cb6c0efc275e1df1736f6e90d4d73
        test -f ${hello.gitlibs}/libs/io.github.clojure/tools.build/deedd623574e3712687a657691c6b79f5026b3a1/deps.edn
        touch $out
      '';

  # An application whose local dependency lies outside its directory, in
  # a source root that holds both. Its test command runs the application,
  # which needs the dependency of the library.
  mono =
    (build {
      src = ./fixtures/mono;
      projectDir = "app";
    }).tests;

  # A fetchgit replacement fetches the git dependencies, the way a private
  # repository is fetched with the credentials of the user. The rebuilt
  # bare repositories check that each checkout holds its commit.
  hello-fetchgit-override =
    (build {
      src = ./fixtures/hello;
      fetchers.fetchgit =
        args:
        builtins.fetchGit {
          inherit (args) url rev;
          narHash = args.hash;
        };
    }).gitlibs;

  # A lockfile for another directory of the source root, and one of another
  # program, are refused at evaluation.
  lock-refused =
    assert refuses (helloLockWith {
      projectDir = "elsewhere";
    });
    assert refuses (builtins.toFile "clojure-cli-purifier.lock.json" ''{ "packages": {} }'');
    assert refuses (helloLockWith {
      version = 1;
    });
    pkgs.runCommand "lock-refused" { } "touch $out";

  # A lockfile older than the project: the builder refuses a lockfile made
  # from another project definition or with another Clojure CLI, and
  # prefetch refuses an edited project, naming `clojure-cli-purifier lock`.
  conformance-stale =
    assert refuses (helloLockWith {
      definitionHash = "0000";
    });
    assert refuses (helloLockWith {
      clojureVersion = "0.0.0";
    });
    commandRefuses "conformance-stale" {
      lockFile = helloLockPath;
      edit = "echo ';; edited' >>deps.edn";
      expect = "changed after .*; run clojure-cli-purifier lock";
    };

  # A lockfile with a changed hash and the contentHash of the lock run is
  # refused by the builder and by prefetch.
  conformance-tampered =
    let
      tampered = builtins.toFile "clojure-cli-purifier.lock.json" (
        builtins.toJSON (
          helloLock
          // {
            artifacts = map (
              entry:
              if entry.path == "org/clojure/data.json/2.5.1/data.json-2.5.1.jar" then
                entry // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
              else
                entry
            ) helloLock.artifacts;
          }
        )
      );
    in
    assert refuses tampered;
    commandRefuses "conformance-tampered" {
      lockFile = tampered;
      expect = "does not match its contentHash.*run clojure-cli-purifier lock --force";
    };

  # A lockfile without a file the build needs fails the build, with a
  # message that names `clojure-cli-purifier lock`.
  conformance-missing =
    let
      failure =
        pkgs.testers.testBuildFailure
          (build {
            src = ./fixtures/hello;
            lockFile = missingLock;
          }).packages.hello;
    in
    pkgs.runCommand "conformance-missing" { } ''
      grep -q 'does not hold. Run clojure-cli-purifier lock' ${failure}/testBuildFailure.log
      touch $out
    '';

  # A lockfile that is not valid fails, naming the command to run: one cut
  # short and one of another program, in the builder and in prefetch.
  # tests/negative.sh checks the messages of Nix.
  conformance-malformed =
    assert refuses (builtins.toFile "clojure-cli-purifier.lock.json" ''{ "version": 2, '');
    assert refuses (builtins.toFile "clojure-cli-purifier.lock.json" ''{ "packages": {} }'');
    commandRefuses "conformance-malformed" {
      lockFile = builtins.toFile "clojure-cli-purifier.lock.json" ''{ "version": 2, '';
      expect = "is not a JSON object.*run clojure-cli-purifier lock --force";
    };

  # A second build of hello, as another derivation, writes the same jars
  # and POM byte for byte. The launchers name their own store path, so
  # they differ.
  conformance-rebuild =
    let
      again = hello.packages.hello.overrideAttrs { purifierRebuild = 2; };
    in
    pkgs.runCommand "conformance-rebuild" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
      test ${hello.packages.hello} != ${again}
      diff -r ${hello.packages.hello}/share/java ${again}/share/java
      touch $out
    '';

  # After prefetch, the everyday loop of hello runs in the sandbox, which
  # has no network: the tests, the SNAPSHOT and the version range aliases,
  # and the uberjar build.
  conformance-offline =
    pkgs.runCommand "conformance-offline"
      {
        nativeBuildInputs = [
          cli
          fakeNixBuild
        ];
      }
      ''
        export HOME="$TMPDIR/home" CLJ_CONFIG="$TMPDIR/config"
        export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$TMPDIR"
        cp -r ${./fixtures/hello} hello
        chmod -R u+w hello
        cd hello
        clojure-cli-purifier prefetch
        export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
        clojure -M:test >test.out
        grep -q '0 failures, 0 errors' test.out
        clojure -M:snapshot | grep -qx '<b>snapshot</b>'
        clojure -M:range | grep -qx 'range 49'
        clojure -T:build uber
        ${hello.jdk}/bin/java -jar target/hello-1.0.0-standalone.jar | grep -qx '<p>purified</p>'
        touch $out
      '';

  # hello kept external: its source holds no lockfile, and the lockfile
  # lies outside it.
  conformance-external =
    (build {
      src = builtins.path {
        path = ./fixtures/hello;
        name = "hello";
        filter = path: _: baseNameOf path != "clojure-cli-purifier.lock.json";
      };
      lockFile = helloLockPath;
    }).packages.hello;

  # A real-world project kept external: honeysql at a fixed commit, built
  # and tested from the lockfile in tests/real-world/honeysql.
  real-world-honeysql =
    (build {
      src = honeysqlSrc;
      lockFile = ./real-world/honeysql/clojure-cli-purifier.lock.json;
    }).tests;
}
