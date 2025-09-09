import std/[syncio, strformat, sequtils, strutils, sugar]

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
    
proc writeOther*(path: string, packages: seq[OtherPkg]) =
  var content = fmt"<otherdata xmlns='http://linux.duke.edu/metadata/other' packages='{packages.len}'>"
  for p in packages:
    let changelogs = p.changelogs.map(c => fmt"<changelog author='{c.author}' date='{c.date}'>{c.message}</changelog>").join
    content.add fmt"<package pkgid='{p.pkgid}' name='{p.name}' arch='{p.arch}'><version epoch='{p.epoch}' ver='{p.ver}' rel='{p.rel}'/>{changelogs}</package>"
  content.add "</otherdata>"
  let f = open(path, fmWrite)
  defer: close f
  f.write(content)