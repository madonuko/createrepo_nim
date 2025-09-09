import
  std/[
    options, paths, dirs, os, tables, osproc, asyncfutures, asyncdispatch, strformat,
    times, strutils, sets
  ]

import ./[cache, rpm]
import ./repodata/[filelists, primary, other, group, repomd]

proc make_rpm(path: string, cache: var Cache): Rpm =
  let mtime = getFileInfo(path).lastWriteTime.toUnix
  if path in cache and cache[path].mtime == mtime:
    return cache[path].rpm
  result = rpm(path)
  cache[path] = (mtime, result)

iterator findAllRpms(path: Path): Path =
  for path in walkDirRec(
    path, relative = true, skipSpecial = true, followFilter = {pcDir, pcLinkToDir}
  ):
    if ($path).endsWith(".rpm"):
      yield path

proc zstdCompressFile(src, dest: string): Future[int64] {.async.} =
  ## Compress src file to dest using zstd
  let p = startProcess(
    findExe("zstd"), args = ["-q", "-f", "-o", dest, src], options = {poParentStreams}
  )
  while p.running:
    await sleepAsync(200)
  let code = p.waitForExit
  if code != 0:
    raise newException(OSError, "zstd compression failed for: " & src)
  getFileInfo(dest).size.int64

proc handleXml[T](
    rpms: T, typ: string, f: proc(path: string, pkgs: T): Future[int64]
): Future[Data] {.async.} =
  result.osize = some uint64 await f(fmt"/tmp/createrepo_nim/{typ}.xml", rpms)
  result.osum = some sha256sum(fmt"/tmp/createrepo_nim/{typ}.xml")
  result.size = uint64 await zstdCompressFile(
    fmt"/tmp/createrepo_nim/{typ}.xml", fmt"./repodata/{typ}.xml.zst"
  )
  result.csum = sha256sum(fmt"./repodata/{typ}.xml.zst")
  moveFile(fmt"./repodata/{typ}.xml.zst", fmt"./repodata/{result.csum}-{typ}.xml.zst")
  result.typ = typ
  result.location_href = fmt"./repodata/{result.csum}-{typ}.xml.zst"

proc createrepo_nim(repo_path = ".", comps = "", cache = "/tmp/createrepo_nim/cache") =
  ## Alternative to createrepo_c
  ##
  ## Scans `repo_path` recursively to find all RPMs, then remove and recreate `./repodata/`.
  var (cachePath, cache) = (cache, getCache(cache))
  var ec = initHashSet[string](cache.len) # existence check
  for k in cache.keys:
    ec.incl k
  var filelists: seq[FileListPkg] = @[]
  var primary: seq[PrimaryPkg] = @[]
  var other: seq[OtherPkg] = @[]
  for path in findAllRpms repo_path.Path:
    ec.excl path.string
    let rpm = make_rpm(path.string, cache)
    filelists.add(rpm.filelist)
    primary.add(rpm.primary)
    other.add(rpm.other)
  if dirExists(fmt"./repodata"):
    removeDir(fmt"./repodata")
  createDir(fmt"./repodata")
  createDir("/tmp/createrepo_nim")
  var data = waitFor all(
    handleXml(filelists, "filelists", writeFilelists),
    handleXml(primary, "primary", writePrimary),
    handleXml(other, "other", writeOther),
  )
  if comps != "":
    data.add waitFor handleXml(comps, "group", writeGroup)
  writeRepomd("./repodata/repomd.xml", data)
  for k in ec:
    cache.del k
  writeCache(cachePath, cache)

when isMainModule:
  import cligen
  dispatch createrepo_nim,
    help =
      {"repo_path": "path to the repo (not repodata!)", "comps": "path to comps.xml"}
