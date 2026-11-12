# SPDX-License-Identifier: MIT
#
# readLock: the clojure-cli-purifier lockfile of a project, read into the
# lock in memory of the purifier contract:
#
#   {
#     purifier = "clojure-cli-purifier";
#     entries  = the Maven files, the recorded repository metadata and the
#                git checkouts, as entries of the shared purifier library;
#     outputs  = { <name> = { files, pom, mainClasses }; }, the package of
#                the project;
#     problems = why the lockfile cannot be used, each naming the command
#                that fixes it;
#     lockfile = the lockfile as JSON, which the builder reads its commands
#                from, or null when it is not valid;
#   }
#
# The Clojure CLI keeps no lockfile of its own, so the purifier's lockfile
# holds everything. readLock fails no evaluation, and checkLock of the
# shared purifier library fails it with the problems. It needs no nixpkgs,
# so the builder, the prefetch and the publish step read the lockfile the
# same way.
{
  # The source root: the project root, or the directory given to
  # `clojure-cli-purifier lock --source`.
  src,
  # The directory of the project, which holds deps.edn, relative to `src`.
  projectDir ? ".",
  # The lockfile. A lockfile outside `src` takes the place of any lockfile
  # in `src`.
  lockFile ?
    src + (if projectDir == "." then "" else "/${projectDir}") + "/clojure-cli-purifier.lock.json",
}:
let
  name = toString lockFile;
  text = builtins.readFile lockFile;

  # A lock run writes one JSON object, from "{" to "}" and a newline.
  # builtins.fromJSON stops evaluation on invalid JSON with a message that
  # names neither the lockfile nor the fix, so a lockfile cut short or of
  # another shape is a problem before it is parsed.
  length = builtins.stringLength text;
  trimmed =
    if length > 0 && builtins.substring (length - 1) 1 text == "\n" then length - 1 else length;
  isObject =
    trimmed >= 2
    && builtins.substring 0 1 text == "{"
    && builtins.substring (trimmed - 1) 1 text == "}";
  # A lockfile that passes the test above and is still not valid JSON stops
  # evaluation here, and the error context names the lockfile and the fix.
  parsed = builtins.addErrorContext "while reading ${name}, which is not valid JSON. Run `clojure-cli-purifier lock --force` in the project to write it again." (
    builtins.fromJSON text
  );

  supportedVersion = import ./lock-version.nix;

  # The fields the builder reads. A lockfile without one was edited or cut
  # short after the lock run wrote it.
  requiredFields = [
    "contentHash"
    "clojureVersion"
    "javaVersion"
    "definitionFiles"
    "definitionHash"
    "prepared"
    "build"
    "test"
    "project"
    "pom"
    "outputs"
    "artifacts"
    "metadata"
    "git"
    "gitRepos"
  ];

  # The lock run records the SHA-256 of the lockfile without its
  # contentHash, as JSON with sorted keys and no spaces, which
  # builtins.toJSON also writes. A lockfile edited by hand no longer
  # matches it.
  contentHash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs parsed [ "contentHash" ]));

  # The lock records the hash of the files that decide what the project
  # resolves: deps.edn, the deps.edn of each local dependency, and the
  # build script.
  definitionHash = builtins.hashString "sha256" (
    builtins.concatStringsSep "" (
      map (
        file:
        let
          path = src + "/${file}";
        in
        if builtins.pathExists path then builtins.readFile path else ""
      ) parsed.definitionFiles
    )
  );

  relock = "Run `clojure-cli-purifier lock --force` in the project to write it again.";

  # The first problem, or null. Each test reads only what the earlier ones
  # found valid.
  problem =
    if !isObject then
      "clojure-cli-purifier: ${name} is not a JSON object, so it is not a clojure-cli-purifier lockfile. ${relock}"
    else if !(builtins.isAttrs parsed && parsed ? version) then
      "clojure-cli-purifier: ${name} is not a clojure-cli-purifier lockfile. ${relock}"
    else if parsed.version != supportedVersion then
      "clojure-cli-purifier: ${name} has lock format version ${toString parsed.version}, and this library reads version ${toString supportedVersion}. Run `clojure-cli-purifier lock --force` with the clojure-cli-purifier revision that provides this library."
    else if builtins.filter (field: !(parsed ? ${field})) requiredFields != [ ] then
      "clojure-cli-purifier: ${name} has no ${
        builtins.concatStringsSep ", " (builtins.filter (field: !(parsed ? ${field})) requiredFields)
      }, so it was edited or cut short after the lock run. ${relock}"
    else if parsed.contentHash != contentHash then
      "clojure-cli-purifier: ${name} does not match its contentHash, so it was edited after the lock run. ${relock}"
    else if (parsed.projectDir or ".") != projectDir then
      "clojure-cli-purifier: ${name} was made for the project directory ${parsed.projectDir or "."} of its source root, and the build has projectDir ${projectDir}; pass projectDir = \"${parsed.projectDir or "."}\"."
    else if parsed.definitionHash != definitionHash then
      "clojure-cli-purifier: the project definition in ${toString src} (${builtins.concatStringsSep ", " parsed.definitionFiles}) changed after ${name} was made; run `clojure-cli-purifier lock`."
    else
      null;

  usable = problem == null;
  project = parsed.project;
in
{
  purifier = "clojure-cli-purifier";
  entries = if usable then parsed.artifacts ++ parsed.metadata ++ parsed.git else [ ];
  outputs =
    if usable then
      {
        ${project.name} = {
          files = map (output: output.path) parsed.outputs;
          inherit (parsed) pom;
          mainClasses = builtins.listToAttrs (
            map (output: {
              name = output.path;
              value = output.mainClass;
            }) (builtins.filter (output: output.mainClass != null) parsed.outputs)
          );
        };
      }
    else
      { };
  problems = if usable then [ ] else [ problem ];
  lockfile = if usable then parsed else null;
}
