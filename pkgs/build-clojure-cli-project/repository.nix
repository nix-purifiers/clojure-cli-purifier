# SPDX-License-Identifier: MIT
#
# The local Maven repository of a lock: its file entries and the inline
# entries of the recorded metadata, laid out by the `tree` of the shared
# purifier library, each a link into the store.
#
# The tree holds no `_remote.repositories` tracking files. Maven Resolver
# treats an artifact without a tracking record as installed locally, so the
# Clojure CLI and tools.build resolve offline from it. The recorded
# `resolver-status.properties` files mark each metadata file as checked in
# the year 2100, so the resolver never asks a remote repository for a newer
# version list.
{
  # The functions of the shared purifier library.
  purifier,
  # The lock in memory, from read-lock.nix and checkLock.
  lock,
  # The Nix system whose entries the repository holds.
  system,
  # The packages that `tree` and `fetchEntry` take by name: fetchurl,
  # fetchgit, runCommand, unzip, zstd, python3 and writeText. A fetcher
  # given here replaces nixpkgs' own.
  fetchers,
}:
purifier.tree (
  fetchers
  // {
    name = "clojure-cli-purifier-repository";
    entries = builtins.filter (entry: !(entry ? git)) (purifier.entriesFor system lock);
  }
)
