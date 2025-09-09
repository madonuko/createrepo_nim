import std/[times, options, syncio, strformat, strutils, sugar]

type
  Data* = object of RootObj
    typ*: string
    csum*: string ## <checksum type="sha256" />
    osum*: Option[string] ## <open-checksum type="sha256" />
    location_href*: string
    # timestamp*: uint64
    size*: uint64
    osize*: Option[uint64]
  Repomd* = object of RootObj
    revision*: uint64
    data*: seq[Data]

proc make_data(data: Data): string =
  var inner = fmt"<checksum type='sha256'>{data.csum}</checksum>"
  if data.osum.isSome:
    inner &= fmt"<open-checksum type='sha256'>{data.osum.get}</checksum>"
  inner &= fmt"<location href='{data.location_href}'/>"
  inner &= fmt"<timestamp>{toUnix(getTime())}</timestamp>"
  inner &= fmt"<size>{data.size}</size>"
  if data.osize.isSome:
    inner &= fmt"<open-size>{data.osize.get}</open-size>"
  fmt"<data type='{data.typ}'>{inner}</data>"

proc writeRepomd*(path: string, data: seq[Data]) =
  var f = open(path, fmWrite)
  defer: close f
  let made_data: seq[string] = collect:
    for x in data:
      make_data x
  f.write fmt"<repomd><revision>{toUnix(getTime())}</revision>{made_data.join}</repomd>"
