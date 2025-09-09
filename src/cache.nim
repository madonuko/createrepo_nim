import std/[options, paths, dirs, times, os, sequtils, enumerate, sugar, syncio, streams, tables]
import bingo
import ./[repodata, rpm]

type Cache* = Table[string, tuple[mtime: int64, rpm: Rpm]]

proc getCache*(path: string): Cache =
  if not path.fileExists: return
  try:
    let f = newFileStream(path)
    defer: close f
    f.loadBin result
  except Exception as err:
    echo "cannot load cache: " & $err.name & ": " & err.msg

proc writeCache*(path: string, cache: Cache) =
  let f = newFileStream(path, fmWrite)
  defer: close f
  f.storeBin cache

