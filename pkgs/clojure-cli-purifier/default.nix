# SPDX-License-Identifier: MIT
#
# The clojure-cli-purifier command: `clojure-cli-purifier lock` writes a
# project's lockfile, `clojure-cli-purifier prefetch` builds the locked
# downloads into the store for an offline Clojure CLI, and
# `clojure-cli-purifier publish` deploys what Nix built. It calls the nix-build and nix-hash of the Nix
# installation it runs on.
{
  lib,
  writeShellApplication,
  runCommand,
  callPackage,
  stdenv,
  fetchurl,
  fetchgit,
  zstd,
  python3,
  writeText,
  pkgs,
  # The JVM of the Clojure CLI. The lock records its version, and the Nix
  # build runs on a JDK of the same major version.
  jdk_headless,
  git,
  jq,
  unzip,
  gnutar,
  coreutils,
  findutils,
  gnused,
  gnugrep,
  gawk,
  # The nixpkgs source of this package set, which the prefetch and the
  # publish step build with.
  path,
  # The functions of the shared purifier library, which the default package
  # overlay of this flake passes.
  purifier ? throw "clojure-cli-purifier: the command needs the shared purifier library; take it from the default package overlay of the clojure-cli-purifier flake",
}:
let
  runtimeSource = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../lib-overlays/default
      ../build-clojure-cli-project
      ./realize.nix
      ./release.nix
      ./deploy-projections.clj
      ./maven-aliases.py
    ];
  };
  jdk = jdk_headless;
  clojure' = pkgs.clojure.override { inherit jdk; };

  # The classpath of the deploy tool, resolved offline from its lockfile,
  # which `clojure-cli-purifier lock` made in deploy/. The classpath names
  # files of the local repository under $out, a link to the repository in
  # the store, so the classpath file keeps the repository alive.
  # The command that makes the lockfile is this package, so a checkout
  # without it still builds, with a publish step that says why it cannot
  # run.
  deployLock = ./deploy + "/clojure-cli-purifier.lock.json";
  hasDeployLock = builtins.pathExists deployLock;
  deployRepository = callPackage ../build-clojure-cli-project/repository.nix {
    inherit purifier;
    system = stdenv.hostPlatform.system;
    fetchers = {
      inherit
        fetchurl
        fetchgit
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    };
    lock = purifier.checkLock (import ../../lib-overlays/default/read-lock.nix { src = ./deploy; });
  };

  # The shared purifier library this flake locks, as a flake reference the
  # interactive mode and the publish step evaluate it from.
  purifierLock = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes.purifier.locked;
  purifierRef = "github:${purifierLock.owner}/${purifierLock.repo}/${purifierLock.rev}?narHash=${lib.escapeURL purifierLock.narHash}";
  deployClasspath =
    runCommand "clojure-cli-purifier-deploy-classpath"
      {
        nativeBuildInputs = [
          clojure'
          python3
          jdk
        ];
      }
      ''
        mkdir -p $out/home/.m2 "$TMPDIR/project" "$TMPDIR/config" "$TMPDIR/java-tmp"
        ln -s ${deployRepository} $out/home/.m2/repository
        cp ${./deploy/deps.edn} "$TMPDIR/project/deps.edn"
        echo '{}' >"$TMPDIR/config/deps.edn"
        export HOME="$TMPDIR" CLJ_CONFIG="$TMPDIR/config" CLJ_CACHE="$TMPDIR/cache" GITLIBS="$TMPDIR/gitlibs"
        export CLJ_JVM_OPTS="-Duser.home=$out/home -Djava.io.tmpdir=$TMPDIR/java-tmp"
        export JAVA_CMD=${jdk}/bin/java
        cd "$TMPDIR/project"
        clojure -Spath >$out/classpath
      '';
in
writeShellApplication {
  name = "clojure-cli-purifier";
  runtimeInputs = [
    clojure'
    python3
    jdk
    git
    jq
    unzip
    gnutar
    coreutils
    findutils
    gnused
    gnugrep
    gawk
  ];
  runtimeEnv = {
    PURIFIER_LIB = "${runtimeSource}/pkgs/clojure-cli-purifier";
    PURIFIER_PROJECT_INPUTS_TOOLS = purifier.projectInputsTool;
    PURIFIER_FORMAT = toString (import ../../lib-overlays/default/lock-version.nix);
    PURIFIER_HELPER = ./helper.clj;
    PURIFIER_TOOLS_JAR = "${clojure'}/libexec/clojure-tools-${clojure'.version}.jar";
    PURIFIER_NIXPKGS = "${path}";
    PURIFIER_SHARED_REF = purifierRef;
    PURIFIER_DEPLOY_CLASSPATH = if hasDeployLock then "${deployClasspath}/classpath" else "";
  };
  text = ''
    # The lock records the Java version, and the Nix build runs on the JDK
    # of that major version, so every command runs on this package's JDK
    # and not on the JDK that JAVA_CMD or JAVA_HOME names.
    export JAVA_CMD=${jdk}/bin/java
    unset JAVA_HOME
  ''
  + builtins.readFile ./lib.sh
  + builtins.readFile ./clojure-cli-purifier.sh;
  passthru = {
    inherit jdk deployClasspath;
    clojure = clojure';
  };
}
