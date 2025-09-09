import std/[asyncdispatch, asyncfile, syncio, strformat, sequtils, strutils, sugar]
import ./xmlutils

type
  OtherPkg* = object of RootObj
    pkgid*: string
    name*: string
    arch*: string
    epoch*: int
    ver*: string
    rel*: string
    changelogs*: seq[Changelog]
  Changelog* = object of RootObj
    author*: string
    date*: int
    message*: string
    
proc writeOther*(path: string, packages: seq[OtherPkg]): Future[int64] {.async.} =
  let f = openAsync(path, fmWrite)
  defer: close f
  await f.write fmt"<otherdata xmlns='http://linux.duke.edu/metadata/other' packages='{packages.len}'>"
  for p in packages:
    let changelogs = p.changelogs.map(c => fmt"<changelog author='{xmlEscape(c.author)}' date='{c.date}'>{xmlEscape(c.message)}</changelog>").join
    await f.write fmt"<package pkgid='{p.pkgid}' name='{p.name}' arch='{p.arch}'><version epoch='{p.epoch}' ver='{p.ver}' rel='{p.rel}'/>{changelogs}</package>"
  await f.write "</otherdata>"
  f.getFileSize
