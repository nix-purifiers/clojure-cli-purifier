# SPDX-License-Identifier: MIT
#
# What `clojure-cli-purifier prefetch` builds for the Clojure CLI of the
# everyday loop: one store path that holds the local Maven repository of
# the lock (`repository`) and its gitlibs directory (`gitlibs`). The
# command keeps a GC root on it, so the locked downloads stay in the store
# while the project uses them.
#
# `src` is the source root, `projectDir` the project in it, and `lockFile`
# the lockfile, all as strings. `nixpkgs` is the nixpkgs source the
# clojure-cli-purifier command was built with, and `purifierRef` the locked
# flake reference of the shared purifier library it was built with. So the
# prefetch fetches the way the builder does, and the two share every store
# path.
{
  src,
  projectDir,
  lockFile,
  nixpkgs,
  purifierRef,
}:
let
  pkgs = import nixpkgs { };
  inherit ((builtins.getFlake purifierRef).lib) purifier;
  lock = purifier.checkLock (
    import ../../lib-overlays/default/read-lock.nix {
      src = /. + src;
      lockFile = /. + lockFile;
      inherit projectDir;
    }
  );
  system = pkgs.stdenv.hostPlatform.system;
  fetchers = {
    inherit (pkgs)
      fetchurl
      fetchgit
      runCommand
      unzip
      zstd
      python3
      writeText
      ;
  };
  repository = pkgs.callPackage ../build-clojure-cli-project/repository.nix {
    inherit
      purifier
      lock
      system
      fetchers
      ;
  };
  gitlibs = pkgs.callPackage ../build-clojure-cli-project/gitlibs.nix {
    inherit
      purifier
      lock
      system
      fetchers
      ;
  };
in
pkgs.runCommand "clojure-cli-purifier-env"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    ln -s ${repository} $out/repository
    ln -s ${gitlibs} $out/gitlibs
  ''
