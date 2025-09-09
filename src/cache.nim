import std/[options, paths, dirs, times, os, sequtils, enumerate, sugar, syncio, streams]
import bingo

type Cache = object of RootObj
  rpms: seq[tuple[path: string, mtime: Time]]

proc getCache*(path: string): Cache =
  let f = newFileStream(path)
  defer: close f
  f.loadBin result

proc writeCache*(path: string, rpms: seq[Path]) =
  var cache: Cache
  cache.rpms = rpms.map(r => (path: $r, mtime: getFileInfo($r).lastWriteTime))
  let f = newFileStream(path, fmWrite)
  defer: close f
  f.storeBin cache

