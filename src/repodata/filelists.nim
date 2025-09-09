import std/[syncio, strformat, sequtils, strutils, sugar]

type FileListPkg* = object
  pkgid*: string
  name*: string
  arch*: string
  epoch*: int
  ver*: string
  rel*: string
  files*: seq[tuple[typ: string, path: string]]

proc file(f: tuple[typ: string, path: string]): string =
  if f.typ == "": fmt"<file>{f.path}</file>"
  else: fmt"<file type='{f.typ}'>{f.path}</file>"

proc writeFilelists(path: string, pkgs: seq[FileListPkg]) =
  var f = open(path, fmWrite)
  defer: close f
  f.write fmt"<filelists xmlns='http://linux.duke.edu/metadata/filelists' packages='{pkgs.len}'>"
  for p in pkgs:
    let files = p.files.map(f => file(f)).join
    f.write fmt"<package pkgid='{p.pkgid}' name='{p.name}' arch='{p.arch}'><version epoch='{p.epoch}' ver='{p.ver}' rel='{p.rel}'/>{files}</package>"
  f.write "</filelists>"
