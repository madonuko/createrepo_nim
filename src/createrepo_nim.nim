import
  std/[
    options, dirs, os, tables, osproc, asyncfutures, asyncdispatch, strformat,
    times, strutils, sets, enumerate, macros,
  ]

import ./[cache, rpm, librpm]
import ./repodata/[filelists, primary, other, group, repomd]

type
  JobMsg = object
    idx: int
    path: string
  JobResult = object
    idx: int
    rpm: Rpm

discard rpmReadConfigFiles(nil, nil)
var ts = rpmtsCreate()
# defer: rpmtsFree ts
discard ts.rpmtsSetVSFlags cast[rpmVSFlags](RPMVSF_NOHDRCHK)

type Hub = ref object
  jobs: Channel[JobMsg]
  results: Channel[JobResult]
var hub = new Hub
open hub.jobs
open hub.results

iterator findAllRpms(path: string): string =
  for path in walkDirRec(
    path, relative = true, skipSpecial = true, followFilter = {pcDir, pcLinkToDir}
  ):
    if path.endsWith(".rpm"):
      yield path

proc zstdCompressFile(src, dest: string): Future[int64] {.async.} =
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

proc worker(hub: ptr Hub) {.thread.} =
  var h = headerNew()
  while true:
    let msg = hub.jobs.recv()
    if msg.path == "__STOP__":
      break
    echo msg.path
    let rpmObj = rpm(msg.path, ts, h)
    hub[].results.send(JobResult(idx: msg.idx, rpm: rpmObj))
  discard headerFree(h)

proc createrepo_nim(repo_path = ".", comps = "", cache = "/tmp/createrepo_nim/cache") =
  var (cachePath, cache) = (cache, getCache(cache))
  var ec = initHashSet[string](cache.len)
  for k in cache.keys:
    ec.incl k

  let nthreads = countProcessors() * 4
  var threads = newSeq[Thread[ptr Hub]](nthreads)
  for i, _ in enumerate threads:
    createThread[ptr Hub](threads[i], worker, addr hub)

  var paths: seq[string]
  var mtimes: seq[int64]
  var rpms = initTable[int, Rpm]()
  var jobsSent = 0
  for i, path in enumerate findAllRpms repo_path:
    paths.add path
    ec.excl path
    let mtime = getFileInfo(path).lastWriteTime.toUnix
    mtimes.add mtime
    if path in cache and cache[path].mtime == mtime:
      rpms[i] = cache[path].rpm
    else:
      hub.jobs.send(JobMsg(idx: i, path: path))
      inc jobsSent

  # Send stop signals
  for _ in threads:
    hub.jobs.send(JobMsg(idx: -1, path: "__STOP__"))

  var received = 0
  while received < jobsSent:
    let res = hub.results.recv()
    rpms[res.idx] = res.rpm
    inc received

  close hub.jobs
  close hub.results
  discard rpmtsFree ts
  # joinThreads threads

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

when isMainModule:
  import cligen
  dispatch createrepo_nim,
    help = {
      "repo_path": "path to the repo (not repodata!)",
      "comps": "path to comps.xml",
    }
