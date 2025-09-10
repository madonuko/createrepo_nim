import std/[asyncdispatch, asyncfile, syncio, strformat, strutils, options]

import ./xmlutils

type
  PrimaryPkg* = object of RootObj
    name*: string
    arch*: string
    epoch*: int
    ver*: string
    rel*: string
    checksum*: string
    summary*: string
    description*: string
    packager*: string
    url*: string
    time*: PkgTime
    size*: PkgSize
    location*: string
    format*: PkgFormat
  PkgTime* = object of RootObj
    file*: int
    build*: int
  PkgSize* = object of RootObj
    package*: int
    installed*: int
    archive*: int
  PkgFormat* = object of RootObj
    license*: string
    vendor*: string
    group*: string
    buildhost*: string
    sourcerpm*: string
    header_range_start*: int
    header_range_end*: int
    provides*: seq[PkgDep]
    conflicts*: seq[PkgDep]
    requires*: seq[PkgDep]
    enhances*: seq[PkgDep]
    suggests*: seq[PkgDep]
    supplements*: seq[PkgDep]
    recommends*: seq[PkgDep]
    obsoletes*: seq[PkgDep]
  PkgDep* = object of RootObj
    name*: string
    flags*: Option[string]
    epoch*: Option[int]
    ver*: Option[string]
    rel*: Option[string]

proc make(pkg: PrimaryPkg): string =
  result = "<package type='rpm'>"
  result.add fmt"<name>{pkg.name}</name><arch>{pkg.arch}</arch><version epoch='{pkg.epoch}' ver='{pkg.ver}' rel='{pkg.rel}'/>"
  result.add fmt"<checksum type='sha256' pkgid='YES'>{pkg.checksum}</checksum><summary>{pkg.summary}</summary><description>{pkg.description}</description><packager>{xmlEscape(pkg.packager)}</packager><url>{pkg.url}</url><time file='{pkg.time.file}' build='{pkg.time.build}'/><size package='{pkg.size.package}' installed='{pkg.size.installed}' archive='{pkg.size.archive}'/><location href='{pkg.location}'/><format><rpm:license>{pkg.format.license}</rpm:license><rpm:vendor>{pkg.format.vendor}</rpm:vendor><rpm:group>{pkg.format.group}</rpm:group><rpm:buildhost>{pkg.format.buildhost}</rpm:buildhost><rpm:sourcerpm>{pkg.format.sourcerpm}</rpm:sourcerpm><rpm:header-range start='{pkg.format.header_range_start}' end='{pkg.format.header_range_end}'/><rpm:provides>"
  for provide in pkg.format.provides:
    if provide.flags.isSome:
      result.add(fmt"<rpm:entry name='{provide.name}' flags='{provide.flags.get}' epoch='{provide.epoch.get}' ver='{provide.ver.get}' rel='{provide.rel.get}'/>")
    else:
      result.add(fmt"<rpm:entry name='{provide.name}'/>")
  result.add("</rpm:provides></format></package>")

proc writePrimary*(path: string, pkgs: seq[PrimaryPkg]): Future[int64] {.async.} =
  var f = openAsync(path, fmWrite)
  defer: close f
  await f.write fmt"<metadata xmlns='http://linux.duke.edu/metadata/common' xmlns:rpm='http://linux.duke.edu/metadata/rpm' packages='{pkgs.len}'>"
  for pkg in pkgs:
    await f.write(make(pkg))
  await f.write("</metadata>")
  f.getFileSize
