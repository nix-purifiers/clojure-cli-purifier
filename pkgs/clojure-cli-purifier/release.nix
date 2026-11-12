# SPDX-License-Identifier: MIT
#
# What `clojure-cli-purifier publish` builds: the release of the project at
# `projectDir` of the source root `src`, from `lockFile`, with the nixpkgs
# source and the shared purifier library the clojure-cli-purifier command
# was built with. All five arguments are strings: `src`, `lockFile` and
# `nixpkgs` are absolute paths, and `purifierRef` is a locked flake
# reference.
{
  nixpkgs,
  purifierRef,
  src,
  projectDir,
  lockFile,
}:
let
  pkgs = import nixpkgs { };
  inherit ((builtins.getFlake purifierRef).lib) purifier;
  build = pkgs.callPackage ../build-clojure-cli-project { inherit purifier; };
  built = build {
    src = builtins.path {
      path = /. + src;
      name = "clojure-source";
    };
    lockFile = /. + lockFile;
    inherit projectDir;
  };
  repository = built.projections.maven;
in
pkgs.runCommand "clojure-publication-repository" { } ''
  mkdir -p $out
  ln -s ${repository} $out/repository
  ln -s ${repository.catalog} $out/catalog.json
''
