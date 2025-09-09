import std/[asyncdispatch, strutils, os]
  
proc writeGroup*(path: string, comps: string): Future[int64] {.async.} =
  copyFile(comps, path)
  comps.getFileInfo.size
