# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.clojure-cli-purifier`, made with lib.makeScope. The scope
# holds the builder `buildClojureCliProject`
# (pkgs/build-clojure-cli-project/default.nix) and the command `cli`
# (pkgs/clojure-cli-purifier). Both take the shared purifier library
# `purifier` by name from the scope's callPackage, which is no attribute of
# the scope, because the flake exports the attributes of the scope as
# packages. The builder is a package for callPackage in that scope, so it
# takes the packages it needs by name, and
# `buildClojureCliProject.override` replaces any of them.
# `clojure-cli-purifier.overrideScope` replaces what the whole scope shares.
# A package takes the scope by name:
#
#   { clojure-cli-purifier }: clojure-cli-purifier.buildClojureCliProject { src = ./.; }
#
# A consumer that lists this flake in `projects` holds the overlay as
# `clojure-cli-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = final: prev: {
    clojure-cli-purifier =
      final.lib.makeScope (extra: final.newScope ({ inherit (closure-lib) purifier; } // extra))
        (
          self:
          import ../../pkgs { inherit (self) callPackage; }
          // {
            # Sandboxed builds use the native CLI, not the interactive wrapper.
            buildClojureCliProject = self.callPackage ../../pkgs/build-clojure-cli-project/default.nix {
              clojure = final.clojure;
            };
          }
        );
  };
}
