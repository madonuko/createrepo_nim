import std/[options, paths, dirs, os, tables, osproc, asyncfutures, asyncdispatch, strformat, sugar]

import ./[cache, rpm]
import ./repodata/[filelists, primary, other, repomd]

proc make_rpm(path: string, cache: var Cache): Rpm =
  # stat and check mtime
  let mtime = getFileInfo(path).lastWriteTime
  if cache.hasKey(path) and cache[path].mtime == mtime:
    return cache[path].rpm
  result = rpm(path, mtime)
  cache[path] = (mtime, result)

iterator findAllRpms(path: Path): Path =
  for path in walkDirRec(
    path, relative = true, skipSpecial = true, followFilter = {pcDir, pcLinkToDir}
  ):
    if path.splitFile.ext == "rpm":
      yield path

proc zstdCompressFile(src, dest: string): Future[int64] {.async.} =
  ## Compress src file to dest using zstd
  let p = startProcess("zstd", args=["-q", "-f", "-o", dest, src], options = {poParentStreams})
  while p.running:
    await sleepAsync(200)
  let code = p.waitForExit
  if code != 0:
    raise newException(OSError, "zstd compression failed for: " & src)
  getFileInfo(dest).size.int64

proc handleXml[T](rpms: seq[T], typ: string, f: proc(path: string, pkgs: seq[T]): Future[int64]): Future[tuple[csum, osum: string, size, osize: uint64]] {.async.} =
  result.size = uint64 await f(fmt"/tmp/createrepo_nim/{typ}.xml", rpms)
  result.csum = sha256sum(fmt"/tmp/createrepo_nim/{typ}.xml")
  result.osize = uint64 await zstdCompressFile(fmt"/tmp/createrepo_nim/{typ}.xml", fmt"./repodata/{result.csum}-{typ}.xml.zst")
  result.osum = sha256sum(fmt"./repodata/{result.csum}-{typ}.xml.zst")

proc main(repo_path: string, comps = "", cache = "/tmp/createrepo_nim/cache") =
  ## Alternative to createrepo_c
  ##
  ## Scans `repo_path` recursively to find all RPMs, then populate/update `repodata/` automatically.
  var cache = getCache(cache)
  var filelists: seq[FileListPkg] = @[]
  var primary: seq[PrimaryPkg] = @[]
  var other: seq[OtherPkg] = @[]
  for path in findAllRpms repo_path.Path:
    let rpm = make_rpm(path.string, cache)
    filelists.add(rpm.filelist)
    primary.add(rpm.primary)
    other.add(rpm.other)
  let s = waitFor all(
    handleXml(filelists, "filelists", writeFilelists),
    handleXml(primary, "primary", writePrimary),
    handleXml(other, "other", writeOther),
  )
  writeRepomd("./repodata/repomd.xml", @[
    Data(typ:"filelists", csum:s[0].csum, osum:some s[0].osum, location_href:fmt"./repodata/{s[0].csum}-filelists.xml.zst", size:s[0].size, osize: some s[0].osize),
    Data(typ:"primary", csum:s[1].csum, osum:some s[1].osum, location_href:fmt"./repodata/{s[1].csum}-primary.xml.zst", size:s[1].size, osize: some s[1].osize),
    Data(typ:"other", csum:s[2].csum, osum:some s[2].osum, location_href:fmt"./repodata/{s[2].csum}-other.xml.zst", size:s[2].size, osize: some s[2].osize)
  ])

when isMainModule:
  import cligen
  dispatch main,
    help =
      {"repo_path": "path to the repo (not repodata!)", "comps": "path to comps.xml"}
