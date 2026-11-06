# SPDX-License-Identifier: MIT
#
# buildClojureCliProject: the sandboxed build of a deps.edn project, from
# the lockfile `clojure-cli-purifier lock` writes.
#
# The file is a package for callPackage: the first argument set is what it
# takes by name, and the result is the builder. The default package overlay
# of the flake adds it as `buildClojureCliProject` in the scope
# `pkgs.clojure-cli-purifier`, and `buildClojureCliProject.override`
# replaces what it takes. A package takes the scope by name:
#
#   { clojure-cli-purifier }:
#   (clojure-cli-purifier.buildClojureCliProject { src = ./.; }).packages.<name>
#
# The builder returns
#
#   packages.<name>  the project's outputs in share/java, its POM there when
#                    the build writes one, and a launcher in bin for each
#                    output jar with a main class, under the project's name
#   tests            the same build, which also runs the test commands of
#                    the lock
#   release          the jar and the POM that `clojure-cli-purifier
#                    publish` deploys
#   fetches          the entries of the lock: the Maven files, the recorded
#                    repository metadata and the git checkouts
#   repository       the local Maven repository of the lock
#   gitlibs          the gitlibs directory of the lock
#   lock             the lock in memory, from readLock
#   jdk              the JDK the build runs on
#   clojure          the Clojure CLI the build runs
{
  lib,
  stdenvNoCC,
  runCommand,
  # The packages that the shared purifier library takes by name to fetch the
  # downloads and to unpack and lay them out.
  fetchurl,
  fetchgit,
  unzip,
  zstd,
  python3,
  writeText,
  callPackage,
  makeWrapper,
  stripJavaArchivesHook,
  git,
  # The JDKs a build can run on. The default JDK of a build is the headless
  # one of the major version its lock was made with.
  javaPackages,
  clojure,
  # The functions of the shared purifier library, which fetches the locked
  # downloads.
  purifier,
}:
{
  # The source root: the project root, or the directory given to
  # `clojure-cli-purifier lock --source`, which holds the project and its
  # local dependencies.
  src,
  # The directory of the project, which holds deps.edn, relative to `src`.
  projectDir ? ".",
  # The lockfile. The default is the one `clojure-cli-purifier lock` writes
  # at the project root. A lockfile outside `src` takes the place of any
  # lockfile in `src`, so a packaging flake builds a project that holds no
  # lockfile.
  lockFile ?
    src + (if projectDir == "." then "" else "/${projectDir}") + "/clojure-cli-purifier.lock.json",
  # The fetchers that replace nixpkgs' own, which the shared purifier
  # library's fetchEntry and tree take, such as a `fetchurl` that sends
  # credentials or reads a company mirror, or a `fetchgit` for a private
  # repository. Each takes the arguments of the nixpkgs fetcher of the same
  # name. builtins.fetchGit fetches at evaluation time with the ssh agent
  # and git configuration of the user, and still checks the locked hash:
  #
  #   fetchers.fetchgit = args: builtins.fetchGit {
  #     inherit (args) url rev;
  #     narHash = args.hash;
  #   };
  fetchers ? { },
  # Nix-built JVM projects; native module selection comes from their catalogs.
  projectDependencies ? purifier.lockedProjectInputs {
    inputs = (builtins.fromJSON (builtins.readFile lockFile)).projectInputs or [ ];
    system = stdenvNoCC.hostPlatform.system;
  },
  # The JDK that runs the Clojure CLI and the project's JVMs.
  jdk ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out build outputs and
  # editor state.
  srcFilter ? null,
}:
let
  # The lock in memory. checkLock stops evaluation with the problems of an
  # unusable lockfile, among them a project whose definition changed after
  # locking, which would resolve downloads the lock does not hold.
  checked = purifier.checkLock (import ./read-lock.nix { inherit src projectDir lockFile; });
  # The lockfile itself, which holds the commands and outputs of the build.
  lock = checked.lockfile;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (
        type == "directory"
        && (
          name == "target"
          || name == ".cpcache"
          || name == ".lsp"
          || name == ".clj-kondo"
          || name == ".clojure-cli-purifier"
        )
      )
      || name == ".git"
      || name == ".idea"
      || name == ".nrepl-port"
      || lib.hasPrefix "result" name
    );

  # The unpack phase copies the source to a directory of this name.
  srcName = "clojure-source";
  filteredSrc = builtins.path {
    path = src;
    name = srcName;
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  javaMajor = builtins.head (lib.splitString "." (lib.removePrefix "1." lock.javaVersion));
  defaultJdk =
    javaPackages.compiler."openjdk${javaMajor}".headless
      or (throw "clojure-cli-purifier: javaPackages has no openjdk${javaMajor} for the Java ${lock.javaVersion} the lock was made with; pass `jdk`.");
  jdk' = if jdk != null then jdk else defaultJdk;
  clojure' = clojure.override { jdk = jdk'; };

  # The packages that fetchEntry and tree take by name, with the fetchers
  # of the caller in place of nixpkgs' own.
  libraryPackages = {
    inherit
      fetchurl
      fetchgit
      runCommand
      unzip
      zstd
      python3
      writeText
      ;
  }
  // fetchers;
  system = stdenvNoCC.hostPlatform.system;

  repository = callPackage ./repository.nix {
    inherit purifier system;
    fetchers = libraryPackages;
    lock = checked;
  };
  provided = purifier.jvmProjections {
    repository = null;
    dependencies = projectDependencies;
    inherit runCommand python3;
    name = "clojure-provided-dependencies";
  };
  gitlibs = callPackage ./gitlibs.nix {
    inherit purifier system;
    fetchers = libraryPackages;
    lock = checked;
  };

  project = lock.project;

  clojureCommands = lib.concatMapStringsSep "\n" (
    args: "purifierClojure ${lib.escapeShellArgs args}"
  );

  javaDirectory = "share/java";

  launchers = builtins.filter (output: output.mainClass != null) lock.outputs;
  # One launcher takes the project's name, and several take the names of
  # their jars.
  launcherName =
    output:
    if builtins.length launchers == 1 then
      project.name
    else
      lib.removeSuffix ".jar" (baseNameOf output.path);

  build =
    { check }:
    stdenvNoCC.mkDerivation {
      pname = project.name + lib.optionalString check "-tests";
      version = if project.version != null then project.version else "0";
      src = filteredSrc;
      # The build runs in the project directory of the source root.
      sourceRoot = srcName + lib.optionalString (projectDir != ".") "/${projectDir}";
      # tools.build writes each jar entry with the time of the build, and
      # stripJavaArchivesHook sets every entry to a fixed time in the fixup
      # phase, so a rebuild writes the same jars.
      nativeBuildInputs = [
        jdk'
        clojure'
        git
        stripJavaArchivesHook
      ]
      ++ lib.optional (launchers != [ ]) makeWrapper;
      dontConfigure = true;
      doCheck = check;
      passthru = lib.optionalAttrs (releaseProblem == null) {
        projections = purifier.jvmProjections {
          repository = release;
          runtimeRepository = "${package}/nix-support/runtime";
          dependencies = projectDependencies;
          inherit runCommand python3;
          name = "clojure-jvm-publications";
        };
      };

      # `clojure-cli-purifier lock` runs the Clojure CLI the same way, so a
      # lock made with it holds what this needs: the local repository and
      # the gitlibs directory hold every download, and no user configuration
      # applies. The JVMs find the repository through user.home, which HOME
      # does not set.
      preBuild = ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME/.m2/repository" "$TMPDIR/config" "$TMPDIR/java-tmp"
        cp -rs --no-preserve=mode ${repository}/. "$HOME/.m2/repository"
        # Maven Resolver rewrites the metadata records it reads, so those
        # are writable copies.
        find "$HOME/.m2/repository" -type l \( -name 'maven-metadata*.xml' -o -name resolver-status.properties \) \
          -exec cp --remove-destination --no-preserve=mode -L {} {}.tmp \; -exec mv {}.tmp {} \;
        export GITLIBS="$TMPDIR/gitlibs"
        mkdir -p "$GITLIBS"
        # A git dependency that needs preparing is prepared in its checkout,
        # so the checkouts are writable copies.
        cp -rL --no-preserve=mode ${gitlibs}/. "$GITLIBS"
        ${
          if projectDependencies == [ ] then
            ''echo '{}' >"$TMPDIR/config/deps.edn"''
          else
            ''
                  cp -r --remove-destination --no-preserve=mode ${provided.maven}/. "$HOME/.m2/repository"
                  ${python3}/bin/python ${purifier.jvmRepositoryTool} \
                    --clojure-config --catalog ${provided.maven.catalog} > "$TMPDIR/config/deps.edn"
              ${jdk'}/bin/java -cp '${clojure'}/libexec/*' clojure.main \
                ${purifier.clojureRewriteTool} "$TMPDIR/config/deps.edn" "$PWD"
              ${jdk'}/bin/java -cp '${clojure'}/libexec/*' clojure.main \
                ${purifier.clojureRewriteTool} "$TMPDIR/config/deps.edn" "$GITLIBS"
            ''
        }
        export CLJ_CONFIG="$TMPDIR/config"
        export CLJ_CACHE="$TMPDIR/cpcache"
        export CLJ_JVM_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR/java-tmp"
        export JAVA_OPTS="$CLJ_JVM_OPTS"
        export JAVA_CMD=${jdk'}/bin/java
        # The Clojure compiler orders the fields of a closure by the
        # identity hash codes of its locals, which differ between JVM runs,
        # so ahead-of-time compiled classes would differ between builds.
        # hashCode=2 gives every object the same identity hash code. The
        # JVMs that tools.build starts read JAVA_TOOL_OPTIONS too.
        export JAVA_TOOL_OPTIONS="-XX:+UnlockExperimentalVMOptions -XX:hashCode=2"
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        # Runs the Clojure CLI. When it fails to resolve a download, the
        # lockfile lacks that download, and the message says how to renew
        # it.
        purifierClojure() {
          ${lib.optionalString (projectDependencies != [ ]) ''
            local -a invocation=("$@")
            local selected=false
            local index
            for (( index=0; index<''${#invocation[@]}; index++ )); do
              case "''${invocation[$index]}" in
                -M|-M:*|-X|-X:*|-T:*)
                  invocation[$index]="''${invocation[$index]}:nix-purifier-project-inputs"
                  selected=true
                  break
                  ;;
              esac
            done
            if ! "$selected"; then
              invocation=(-A:nix-purifier-project-inputs "''${invocation[@]}")
            fi
          ''}
          if clojure ${
            if projectDependencies == [ ] then ''"$@"'' else ''"''${invocation[@]}"''
          } > >(tee "$TMPDIR/clojure.log") 2>&1; then
            return 0
          fi
          if grep -qE 'could not be resolved|Could not transfer|Could not find artifact|Failed to read artifact descriptor|Unable to clone|Network is unreachable' "$TMPDIR/clojure.log"; then
            echo "clojure-cli-purifier: the Clojure CLI tried to download something ${toString lockFile} does not hold. Run clojure-cli-purifier lock in the project, which records every download again." >&2
          fi
          return 1
        }
        # Git dependencies that need preparing are prepared for the aliases
        # the lock prepared, as the lock run did.
        purifierClojure -X:deps prep :aliases ${lib.escapeShellArg "[${lib.concatStringsSep " " (lock.prepared ++ lib.optional (projectDependencies != [ ]) ":nix-purifier-project-inputs")}]"}
      '';
      buildPhase = ''
        runHook preBuild
        ${clojureCommands lock.build}
        ${lib.optionalString (releaseProblem == null) ''
          export PURIFIER_RUNTIME_BASIS="$TMPDIR/runtime-basis.json"
          purifierClojure -M ${./runtime-basis.clj}
        ''}
        runHook postBuild
      '';
      checkPhase = ''
        runHook preCheck
        ${clojureCommands lock.test}
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/${javaDirectory}"
        for output in ${lib.escapeShellArgs (map (output: output.path) lock.outputs)}; do
          if [ ! -f "$output" ]; then
            echo "clojure-cli-purifier: the lock names $output, which this build of ${project.name} did not produce; run clojure-cli-purifier lock --force" >&2
            exit 1
          fi
          cp "$output" "$out/${javaDirectory}/"
        done
        ${lib.optionalString (lock.pom != null) ''
          ${lib.optionalString (projectDependencies != [ ]) ''
            ${python3}/bin/python ${purifier.jvmRepositoryTool} \
              --rewrite-pom ${lib.escapeShellArg lock.pom} --catalog ${provided.maven.catalog}
          ''}
          cp ${lib.escapeShellArg lock.pom} "$out/${javaDirectory}/${project.name}-${project.version}.pom"
        ''}
        ${lib.concatMapStrings (output: ''
          makeWrapper ${jdk'}/bin/java "$out/bin/${launcherName output}" \
            --add-flags "-jar $out/${javaDirectory}/${baseNameOf output.path}"
        '') launchers}
        runHook postInstall
      '';
      # Preserve canonical foreign bytes: normalize only our own archives.
      postFixup = lib.optionalString (releaseProblem == null) ''
        ${python3}/bin/python ${./export-runtime.py} ${purifier.projectInputsTool} \
          "$TMPDIR/runtime-basis.json" "$HOME/.m2/repository" ${provided.maven.catalog} \
          "$out/nix-support" "$out/${javaDirectory}/${project.name}-${project.version}.pom"
      '';
      meta = {
        description = "${project.group}/${project.name}, built by clojure-cli-purifier";
      }
      // lib.optionalAttrs (launchers != [ ]) { mainProgram = launcherName (builtins.head launchers); };
    };

  package = build { check = false; };

  # The jar that publishing deploys is named after the project and its
  # version, as tools.build names the jar of a library.
  releaseJar = "${project.name}-${toString project.version}.jar";
  releaseProblem =
    if lock.pom == null then
      "the build of ${toString lockFile} writes no POM, which a release needs"
    else if !(builtins.any (output: baseNameOf output.path == releaseJar) lock.outputs) then
      "the build of ${toString lockFile} makes no ${releaseJar}, which a release needs"
    else
      null;
  release =
    if releaseProblem != null then
      throw "clojure-cli-purifier: ${releaseProblem}; give `clojure-cli-purifier lock` a --build that writes them."
    else
      runCommand "${project.name}-${project.version}-release" { } ''
        mkdir -p $out
        cp ${package}/${javaDirectory}/${releaseJar} $out/
        cp ${package}/${javaDirectory}/${project.name}-${project.version}.pom $out/
        if [ -d ${package}/nix-support/local-publications ]; then
          cp -r ${package}/nix-support/local-publications/. $out/
        fi
      '';
in
assert
  clojure'.version == lock.clojureVersion
  || throw "clojure-cli-purifier: the lock was made with Clojure CLI ${lock.clojureVersion}, and this package set has Clojure CLI ${clojure'.version}. Run `clojure-cli-purifier lock` with the clojure-cli-purifier of this package set.";
{
  projections = purifier.jvmProjections {
    repository = release;
    runtimeRepository = "${package}/nix-support/runtime";
    dependencies = projectDependencies;
    inherit runCommand python3;
    name = "clojure-jvm-publications";
  };
  packages.${project.name} = package;
  tests = build { check = true; };
  inherit release repository gitlibs;
  lock = checked;
  fetches = checked.entries;
  jdk = jdk';
  clojure = clojure';
}
