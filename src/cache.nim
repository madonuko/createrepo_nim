import std/[options, paths, dirs, times, os, sequtils, enumerate, sugar, syncio, streams, tables]
import bingo
import ./[repodata, rpm]

type Cache* = Table[string, tuple[mtime: Time, rpm: Rpm]]

proc getCache*(path: string): Cache =
  try:
    let f = newFileStream(path)
    defer: close f
    f.loadBin result
  except:
    discard

proc writeCache*(path: string, cache: Cache) =
  let f = newFileStream(path, fmWrite)
  defer: close f
  f.storeBin cache

