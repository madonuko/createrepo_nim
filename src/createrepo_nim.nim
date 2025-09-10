import
  std/[
    options, paths, dirs, os, tables, osproc, asyncfutures, asyncdispatch, strformat,
    times, strutils, sets, enumerate, streams, macros,
  ]

import flatty

import ./[cache, rpm, librpm]
import ./repodata/[filelists, primary, other, group, repomd]

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

proc worker() =
  # Read JobMsg from stdin, process, write JobResult to stdout
  discard rpmReadConfigFiles(nil, nil)
  var ts = rpmtsCreate()
  var h = headerNew()
  let stdinStream = newFileStream(stdin)
  let stdoutStream = newFileStream(stdout)
  var idx: int
  var path_len: int
  var path: string
  while true:
    idx = stdinStream.readLine().parseInt
    path_len = stdinStream.readLine().parseInt
    if path_len == 0:
      break
    path = stdinStream.readStr(path_len)
    let rpm = rpm(path, ts, h)
    stdoutStream.writeLine $idx
    let flatty = rpm.toFlatty
    stdoutStream.writeLine $flatty.len
    stdoutStream.write flatty
    stdoutStream.flush()
  discard rpmtsFree(ts)
  discard headerFree(h)

proc parent(repo_path, comps, cache: string) =
  var (cachePath, cache) = (cache, getCache(cache))
  var ec = initHashSet[string](cache.len)
  var rpms = initTable[int, Rpm]()
  for k in cache.keys:
    ec.incl k

  var idx: int
  var len: int
  var workers: seq[Process]
  var next_process = 0
  var first = true
  var paths: seq[string]
  var mtimes: seq[int64]
  let nproc = countProcessors() * 4
  for i in 0 ..< nproc:
    workers.add startProcess(getAppFilename(), args = ["--worker"], options = {})

  for i, path in enumerate findAllRpms repo_path.Path:
    let path = $path
    paths.add path
    ec.excl path
    let mtime = getFileInfo(path).lastWriteTime.toUnix
    mtimes.add mtime.int64
    if path in cache and cache[path].mtime == mtime:
      rpms[i] = cache[path].rpm
    else:
      echo path
      let p = workers[next_process]
      if not first:
        idx = p.outputStream.readLine.parseInt
        len = p.outputStream.readLine.parseInt
        let flatty = p.outputStream.readStr len.int
        rpms[idx.int] = flatty.fromFlatty(Rpm)
      p.inputStream.writeLine $i
      p.inputStream.writeLine $path.len
      p.inputStream.write path
      p.inputStream.flush()
      inc next_process
      if next_process == nproc:
        next_process = 0
        first = false

  let last = if first: next_process else: nproc
  for i in 0 ..< last:
    let p = workers[i]
    idx = p.outputStream.readLine.parseInt
    len = p.outputStream.readLine.parseInt
    let flatty = p.outputStream.readStr len.int
    rpms[idx.int] = flatty.fromFlatty(Rpm)
    p.inputStream.write "0\n0\n"
    p.inputStream.flush()
    discard waitForExit p
    close p

  if first:
    for i in next_process ..< nproc:
      let p = workers[i]
      p.inputStream.write "0\n0\n"
      p.inputStream.flush()
      discard waitForExit p
      close p

  var filelists: seq[FileListPkg] = @[]
  var primary: seq[PrimaryPkg] = @[]
  var other: seq[OtherPkg] = @[]
  for i, rpm in rpms:
    cache[paths[i]] = (mtime: mtimes[i], rpm: rpm)
    filelists.add rpm.filelist
    primary.add rpm.primary
    other.add rpm.other

  if dirExists("./repodata"):
    removeDir("./repodata")
  createDir("./repodata")
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

proc createrepo_nim(
    repo_path = ".", comps = "", cache = "/tmp/createrepo_nim/cache", worker = false
) =
  ## Alternative to createrepo_c
  ##
  ## Scans `repo_path` recursively to find all RPMs, then remove and recreate `./repodata/`.
  if worker:
    worker()
    return
  else:
    parent(repo_path, comps, cache)

when isMainModule:
  import cligen
  dispatch createrepo_nim,
    help = {
      "repo_path": "path to the repo (not repodata!)",
      "comps": "path to comps.xml",
      "worker": "used internally, run as worker process",
    }
