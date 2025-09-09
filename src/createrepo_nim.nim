# This is just an example to get you started. A typical binary package
# uses this file as the main entry point of the application.

import std/options
import cligen

proc main(repo_path: string, comps: string = "") =
  ## Alternative to createrepo_c
  ## Scans `repo_path` recursively to find all RPMs, then populate/update `repodata/` automatically.
  discard

when isMainModule:
  import cligen
  dispatch main, help={"repo_path": "path to the repo (not repodata!)", "comps": "path to comps.xml"}
