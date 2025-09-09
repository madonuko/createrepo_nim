import std/[options, paths, dirs, os, tables]

import ./[cache, repodata, rpm]

proc make_rpm(path: string, cache: var Cache): Rpm =
  # stat and check mtime
  let mtime = getFileInfo(path).lastWriteTime
  if cache.hasKey(path) and cache[path].mtime == mtime:
    let (mtime, rpm) = cache[path]
    return rpm
  result = rpm(path, mtime)
  cache[path] = (mtime, result)

iterator findAllRpms(path: Path): Path =
  for path in walkDirRec(path, relative = true, skipSpecial = true, followFilter = {pcDir, pcLinkToDir}):
    if path.splitFile.ext == "rpm":
      yield path

proc main(repo_path: string, comps = "") =
  ## Alternative to createrepo_c
  ## 
  ## Scans `repo_path` recursively to find all RPMs, then populate/update `repodata/` automatically.
  discard

when isMainModule:
  import cligen
  dispatch main, help={"repo_path": "path to the repo (not repodata!)", "comps": "path to comps.xml"}
