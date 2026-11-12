# SPDX-License-Identifier: MIT
#
# The `clojure-cli-purifier` library namespace, which holds the lockfile
# reader of the purifier contract:
#
#   lib.clojure-cli-purifier.readLock { src, projectDir ? ".", lockFile ? ... }
#
# lib-overlays/default/read-lock.nix lists its arguments and its result. The builder is
# the package `buildClojureCliProject` of the default package overlay.
{ ... }:
{

  overlay = final: prev: {
    clojure-cli-purifier = (prev.clojure-cli-purifier or { }) // {
      readLock = import ./read-lock.nix;
    };
  };

}
