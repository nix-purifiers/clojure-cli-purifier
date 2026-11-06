# clojure-cli-purifier

clojure-cli-purifier keeps the Clojure CLI's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

## Quickstart

From the project root:

```zsh
nix shell \
  'github:nix-purifiers/clojure-cli-purifier#clojure' \
  'github:nix-purifiers/clojure-cli-purifier#cli'
clojure-cli-purifier lock \
  --build '-T:build uber' --test '-M:test'
clojure-cli-purifier prefetch
export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
clojure -T:build uber
clojure -M:test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Use the build and test aliases that your project defines in place of
`:build` and `:test`.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The shell provides the native `clojure` wrapper and the purifier CLI. The wrapper
uses the nearest project's lock and prepares its cache when needed. Without
a purifier lock, it warns on standard error and runs ordinary, impure Clojure.
`prefetch` also supplies a project-local wrapper for shells and editors.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

The Clojure CLI has no lockfile and no plugin interface for locking. So
clojure-cli-purifier is a standalone command, and its lockfile
`clojure-cli-purifier.lock.json` is the only lockfile of the project.

`clojure-cli-purifier prefetch` builds the downloads of the lockfile into
the Nix store, and links `.clojure-cli-purifier/bin/clojure` beside the
lockfile. With that directory first on `PATH`, the project's own `clojure`
commands run on the locked downloads:

```zsh
clojure-cli-purifier prefetch
export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
clojure -M:test
clojure -T:build uber
```

With [direnv](https://direnv.net), an `.envrc` with
`PATH_add .clojure-cli-purifier/bin` sets the same `PATH`. We recommend
adding `.clojure-cli-purifier/` to `.gitignore`.

To add or upgrade a dependency, edit `deps.edn`, then run
`clojure-cli-purifier lock` and `clojure-cli-purifier prefetch`. A relock
keeps the build and test commands of the lockfile. `--build`, `--test`,
`--alias :name` and `--user-aliases` each replace their part of the
lockfile.

A relock also keeps the versions the lockfile chose for version ranges and
SNAPSHOTs, from the repository metadata it recorded.
`clojure-cli-purifier update` resolves them anew, for every library or for
the named ones:

```zsh
clojure-cli-purifier update org.clojure/core.memoize
```

A version that deps.edn names exactly changes when deps.edn does, and a
git dependency changes when its `:git/sha` does.

The user `deps.edn` stays in effect. `lock --user-aliases` also locks its
aliases, so that tools kept there, such as an nREPL alias, run offline too.

`clojure-cli-purifier publish` builds the `release` with Nix and deploys its
jar and POM with [deps-deploy](https://github.com/slipset/deps-deploy).
Nothing is compiled outside the sandbox. The default repository is
Clojars, with `CLOJARS_USERNAME` and `CLOJARS_PASSWORD`.
`--repository ID=URL` deploys to another Maven repository, with the
credentials of the server of the same id in `~/.m2/settings.xml`.
`--dry-run` prints what it would deploy.

## Dependencies from another purified project

Pass a producer's flake package to `lock`:

```zsh
clojure-cli-purifier lock \
  --input 'github:owner/library/<rev>#library'
clojure-cli-purifier prefetch
```

The producer must export a Maven view through `projections.maven`. Its
catalog selects the supplied modules automatically, including their Nix-derived
versions. Keep ordinary dependency declarations in the project; no version
rewrite table is needed. Repeat `--input` for additional producers.

The lock records the producer's pinned Nix source, rather than listing its
artifacts as downloads. Relocking retains that pin; `update` refreshes it.
Conflicting providers of the same module are rejected.

For a Nix build definition, the corresponding builder argument is
`projectDependencies = [ producer.packages.${system}.library ];`. By default,
the builder reads the inputs recorded in the lock.

Project components get Nix-derived versions. The publish command exports
their application dependencies, including local and git libraries, with
POMs ordinary Maven consumers can use. A generated POM that disagrees with
the application's native basis fails publication.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

`packages.hello` is the package of the project, which the example names
`hello`. The result links to `./result`.

The flake's `overlays.default` adds one attribute to a package set: the
scope `clojure-cli-purifier`, which holds the builder
`buildClojureCliProject`, the command and the shared `purifier` library.

A project whose authors want a flake packages itself with the same call.
The flake can lie in the repository of the project or in another one:

```nix
{
  inputs.clojure-cli-purifier.url =
    "github:nix-purifiers/clojure-cli-purifier";
  inputs.nixpkgs.follows =
    "clojure-cli-purifier/nixpkgs";

  outputs =
    { nixpkgs, clojure-cli-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          clojure-cli-purifier.overlays.default
        ];
      };
      project =
        pkgs.clojure-cli-purifier.buildClojureCliProject
          {
            src = ./.;
          };
    in
    {
      packages.${system}.default =
        project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

`buildClojureCliProject` is a package for `callPackage` in that scope. It
takes the packages it needs by name, and
`pkgs.clojure-cli-purifier.buildClojureCliProject.override` replaces any of
them. `pkgs.clojure-cli-purifier.overrideScope` replaces what everything in
the scope shares. Its own arguments are these:

- `src` is the project root, or the source root the lock was made with.
- `projectDir` names the directory of the project in `src`. It is `"."` by
  default, and it must match the lockfile.
- `lockFile` is the lockfile. It defaults to `clojure-cli-purifier.lock.json`
  in the project directory.
- `fetchers` replaces fetchers of nixpkgs, for credentials or a mirror. The
  [purifier](https://github.com/nix-purifiers/purifier) library's
  `fetchEntry` and `tree` take it.
- `jdk` defaults to the headless JDK of the major version the lock was made
  with.
- `srcFilter` filters the source before it goes into the store.

The builder recognizes legacy Java version notation in existing locks:
`1.8.0_504` selects major `8`, while `21.0.12.1` selects `21`. Locks keep
their full recorded version and are not rewritten. The package set must still
provide that JDK, or the caller must pass `jdk`. This parsing does not change
the packaged capture JVM or establish legacy Clojure CLI/JVM compatibility.

The result has these attributes:

- `packages.<name>` holds the jars and the POM in `share/java`, and a
  launcher in `bin` for each uberjar with a main class. `<name>` is the
  artifact id of the POM the build writes, or the name of the project
  directory.
- `tests` is the same build, which also runs the test commands of the lock.
- `release` holds `<artifactId>-<version>.jar` and its POM, which `publish`
  deploys.
- `fetches` lists the Maven files and git checkouts of the build as entries
  of the purifier library.
- `repository` and `gitlibs` are the local Maven repository and the
  gitlibs directory of the lock.

The lockfile names the jars, the POM and the main classes the build
produces, so Nix knows every attribute and every output at evaluation,
without import-from-derivation.

`lib.clojure-cli-purifier.readLock { src, projectDir ? ".", lockFile ? ... }`
reads the lockfile into the shape that every nix-purifier gives, for tools
such as SBOM generators. Its `entries` are the Maven files, the recorded
repository metadata and the git checkouts, and its `outputs` name the
package. Its `problems` list why the lockfile cannot be used, each with
the command that fixes it. The builder fails evaluation with them.

We recommend committing `clojure-cli-purifier.lock.json` to the
repository of the project. The builder and the commands look for it there
by default.

A project can instead keep its build external: the flake that calls the
builder keeps the lockfile outside the source and passes it as `lockFile`,
so that a packaging flake builds a project its author does not change.
Every command takes `--lockfile PATH` or the environment variable
`CLOJURE_CLI_PURIFIER_LOCKFILE`, which a dev shell can set to the same
path. The flag takes precedence over the variable.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/clojure-cli-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.clojure-cli-purifier.buildClojureCliProject {
  src = ./.;
}).packages.hello'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

After a prefetch, `clojure` needs no network. The Maven repository and the
gitlibs directory under `.clojure-cli-purifier` hold exactly the locked
downloads, the git dependencies that need preparing are prepared, and the
JDK and the Clojure CLI come from the store. `.clojure-cli-purifier/env` is
a garbage-collector root, so `nix-collect-garbage` keeps the downloads
while it exists.

## Editor

[clojure-lsp](https://clojure-lsp.io) computes the classpath with
`clojure -Spath`, so it reads the locked downloads when the editor's
environment has `.clojure-cli-purifier/bin` first on `PATH`, such as
through direnv. In a project with a `bb.edn`, clojure-lsp asks babashka for
the classpath, and `.lsp/config.edn` points it at `deps.edn`:

```clojure
{:project-specs [{:project-path "deps.edn"
                  :classpath-cmd ["clojure" "-A:test" "-Spath"]}]}
```

clojure-lsp analyzes the jars on the classpath, which hold the Clojure
sources, and needs no other download.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `the project definition in … changed after … was made; run clojure-cli-purifier lock` | Run `clojure-cli-purifier lock`. |
| `… does not match its contentHash, so it was edited after the lock run` | Run `clojure-cli-purifier lock --force`. |
| `… is not a JSON object, so it is not a clojure-cli-purifier lockfile` | Run `clojure-cli-purifier lock --force`. |
| `… has lock format version …` | Run `clojure-cli-purifier lock --force`. |
| `… was made with Clojure CLI …` | Run `clojure-cli-purifier lock`, with the clojure-cli-purifier of the package set that builds the project. |
| `the Clojure CLI tried to download something … does not hold` | Run `clojure-cli-purifier lock`, then `clojure-cli-purifier prefetch`. |
| `… changed after the last prefetch` | Run `clojure-cli-purifier prefetch`. |
| `hash mismatch in fixed-output derivation` | The server changed a file under its URL. Run `clojure-cli-purifier lock --force`. |

The builder refuses an invalid lockfile at evaluation, and the commands
refuse it before they run anything.

## Supported language repositories

`clojure-cli-purifier lock` copies the project, or the source root that
holds it, to a temporary directory. It runs the Clojure CLI there with an
empty local Maven repository, an empty gitlibs directory (`GITLIBS`) and an
empty user `deps.edn`, which is the environment of a sandboxed build. It
prepares the classpath of the project and of each alias, prepares the git
dependencies that need it (`clojure -X:deps prep`), and runs the build and
test commands. The lockfile records every download:

- **Maven repositories.** Files from Maven Central, Clojars and the
  repositories `deps.edn` adds with `:mvn/repos` are supported. Each file
  is locked by the URL of its repository and its SHA-256.
- **Mirrors.** `lock --mirror ID=URL` downloads the files of the repository
  `ID` from a mirror during the lock run. The lockfile records the
  repository URL, and the mirror as a fallback. The mirrors of
  `~/.m2/settings.xml` are recorded the same way.
- **Version ranges and SNAPSHOT versions.** Maven Resolver picks these from
  repository metadata, whose content changes at its URL, so the lockfile
  holds the metadata the lock run read. The build resolves to the versions
  the lock run picked. A SNAPSHOT file is locked at its timestamped URL.
- **Git dependencies.** Dependencies given by `:git/sha` alone or with
  `:git/tag` are supported, including those that need preparing. The
  Clojure CLI expands a short commit and checks a tag in a bare clone, so
  the lockfile also holds the commit objects and tags the CLI reads. The
  Nix build rebuilds the bare clone from them, and each rebuilt commit has
  exactly the locked hash.
- **Dependencies chosen by architecture.** The lock run resolves the
  project once more for each Linux architecture the flake builds for, with
  the matching `os.arch`.
- **Local dependencies.** A `:local/root` dependency comes from the source.
  A local dependency outside the project needs a source root that holds
  both: `lock --source DIR` names it, and the Nix build takes that
  directory as `src`, with `projectDir` naming the project.
- **Downloads outside the Clojure CLI.** A build script that downloads a
  file itself fails in the sandbox, because the lock records only what the
  Clojure CLI and Maven Resolver fetch.
- **Git files changed by attributes.** A repository whose checkout differs
  from its commit, such as one with Git LFS files, cannot rebuild the
  commit, and the lock run names it.

Maven Resolver reads its proxy only from `settings.xml`. The lock run uses
`~/.m2/settings.xml` with its proxies, mirrors and credentials, and
otherwise writes one with the proxy of `https_proxy`. A Maven repository
that needs credentials in the Nix build takes them through
`fetchers.fetchurl`. A git dependency over ssh can be fetched at evaluation
with the user's ssh agent, and the locked hash still applies:

```nix
clojure-cli-purifier.buildClojureCliProject {
  src = ./.;
  fetchers.fetchgit =
    args:
    builtins.fetchGit {
      inherit (args) url rev;
      narHash = args.hash;
    };
}
```

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### honeysql

[honeysql](https://github.com/seancorfield/honeysql) turns Clojure data
into SQL. The build script of the project runs under babashka, so it has no
Clojure CLI build, and its tests run with `clojure -X:test`. This example
uses an external build: the lockfile lies outside the clone, so the source
of honeysql stays as its author publishes it. A project you own commits its
lockfile instead, as the Quickstart does.

Clone the library, and lock it with the test command:

```zsh
nix shell \
  'github:nix-purifiers/clojure-cli-purifier#clojure' \
  'github:nix-purifiers/clojure-cli-purifier#cli'
git clone https://github.com/seancorfield/honeysql
cd honeysql
clojure-cli-purifier lock \
  --test '-X:test' --lockfile ../honeysql.lock.json
```

Prefetch the downloads, and run the tests with no network:

```zsh
nix shell \
  'github:nix-purifiers/clojure-cli-purifier#clojure' \
  'github:nix-purifiers/clojure-cli-purifier#cli'
export \
  CLOJURE_CLI_PURIFIER_LOCKFILE="$PWD/../honeysql.lock.json"
clojure-cli-purifier prefetch
export PATH="$PWD/.clojure-cli-purifier/bin:$PATH"
clojure -X:test
```

Then build and test it with Nix, from the directory of the clone:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/clojure-cli-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.clojure-cli-purifier.buildClojureCliProject {
  src = ./.;
  lockFile = ../honeysql.lock.json;
}).tests'
```

The build runs the tests of honeysql in the sandbox. After a change to the
`deps.edn` of honeysql, run `lock` again with the same `--lockfile`.

### A library with a build script

A project whose `build.clj` has the usual `jar` function, run through
`clojure -T:build`, locks without extra options:

```zsh
nix shell \
  'github:nix-purifiers/clojure-cli-purifier#clojure' \
  'github:nix-purifiers/clojure-cli-purifier#cli'
clojure-cli-purifier lock \
  --build '-T:build jar' --test '-M:test'
```

Build it from its directory with the expression of the Quickstart.
`packages.<name>` holds the jar and the POM, and `release` is what
`clojure-cli-purifier publish` uploads to Clojars.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

Released under the MIT license; see [LICENSE](LICENSE).
