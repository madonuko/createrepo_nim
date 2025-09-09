import std/[options, paths, dirs]

import ./[cache, repodata]

iterator findAllRpms(path: Path): Path =
  for path in walkDirRec(path, relative = true, skipSpecial = true, followFilter = {pcDir, pcLinkToDir}):
    if path.splitFile.ext == "rpm":
      yield path

proc main(repo_path: string, comps = "") =
  ## Alternative to createrepo_c
  ## Scans `repo_path` recursively to find all RPMs, then populate/update `repodata/` automatically.
  discard

when isMainModule:
  import cligen
  dispatch main, help={"repo_path": "path to the repo (not repodata!)", "comps": "path to comps.xml"}
