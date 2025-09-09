## Process an RPM package
## 
## ? https://github.com/rpm-software-management/createrepo_c/blob/e801cbe98e3e2d120aa480e353c44f0224502de3/src/parsehdr.c#L184
import std/nativesockets # htonl
import std/[strformat, osproc, strutils, options, paths]
import ./librpm
import ./repodata/[primary, other, filelists]

discard rpmReadConfigFiles(nil, nil)

type Rpm* = object
  primary*: PrimaryPkg
  other*: OtherPkg
  filelist*: FileListPkg

proc sha256sum*(path: string): string =
  execCmdEx("sha256sum "&path).output.split(' ')[0]

type DepKind = enum
  depProvides, depRequires, depConflicts, depObsoletes,
  depEnhances, depSuggests, depSupplements, depRecommends

const
  RPMFILE_GHOST = 0x08
  depTags = [
    depProvides: (RPMTAG_PROVIDENAME, RPMTAG_PROVIDEFLAGS, RPMTAG_PROVIDEVERSION),
    depRequires: (RPMTAG_REQUIRENAME, RPMTAG_REQUIREFLAGS, RPMTAG_REQUIREVERSION),
    depConflicts: (RPMTAG_CONFLICTNAME, RPMTAG_CONFLICTFLAGS, RPMTAG_CONFLICTVERSION),
    depObsoletes: (RPMTAG_OBSOLETENAME, RPMTAG_OBSOLETEFLAGS, RPMTAG_OBSOLETEVERSION),
    depEnhances: (RPMTAG_ENHANCENAME, RPMTAG_ENHANCEFLAGS, RPMTAG_ENHANCEVERSION),
    depSuggests: (RPMTAG_SUGGESTNAME, RPMTAG_SUGGESTFLAGS, RPMTAG_SUGGESTVERSION),
    depSupplements: (RPMTAG_SUPPLEMENTNAME, RPMTAG_SUPPLEMENTFLAGS, RPMTAG_SUPPLEMENTVERSION),
    depRecommends: (RPMTAG_RECOMMENDNAME, RPMTAG_RECOMMENDFLAGS, RPMTAG_RECOMMENDVERSION)
  ]

proc flagToStr(num_flags: int): Option[string] =
  case num_flags
  of 2: some("EQ")
  of 4: some("GT")
  of 8: some("LT")
  of 6: some("GE")
  of 10: some("LE")
  else: none(string)

proc parseEVR(evr: string): (Option[int], Option[string], Option[string]) =
  # Parse epoch:version-release
  if evr.len == 0: return (none(int), none(string), none(string))
  let evrParts = evr.split(":")
  if evrParts.len == 2:
    let epoch = some(evrParts[0].parseInt)
    let verRel = evrParts[1].split("-")
    let ver = some(verRel[0])
    let rel = if verRel.len > 1: some(verRel[1]) else: none(string)
    return (epoch, ver, rel)
  else:
    let verRel = evr.split("-")
    let ver = some(verRel[0])
    let rel = if verRel.len > 1: some(verRel[1]) else: none(string)
    return (none(int), ver, rel)

proc collectPCRE(h: Header): tuple[
  provides, requires, conflicts, obsoletes, enhances, suggests, supplements, recommends: seq[PkgDep]
] =
  for kind, tags in depTags:
    let (nameTag, flagsTag, versionTag) = tags
    let names = rpmtdNew()
    let flags = rpmtdNew()
    let versions = rpmtdNew()
    if headerGet(h, cast[rpmTagVal](nameTag), names, 0).bool and
        headerGet(h, cast[rpmTagVal](flagsTag), flags, 0).bool and
        headerGet(h, cast[rpmTagVal](versionTag), versions, 0).bool:
      discard rpmtdInit(names)
      discard rpmtdInit(flags)
      discard rpmtdInit(versions)
      defer:
        discard rpmtdFree(names)
        discard rpmtdFree(flags)
        discard rpmtdFree(versions)  
      while (rpmtdNext(names) != -1 and
              rpmtdNext(flags) != -1 and
              rpmtdNext(versions) != -1):
        let name = $rpmtdGetString(names)
        let num_flags = rpmtdGetNumber(flags).int
        let flagStr = flagToStr(num_flags)
        let evr = $rpmtdGetString(versions)
        let (epoch, ver, rel) = parseEVR(evr)
        let dep = PkgDep(
          name: name,
          flags: flagStr,
          epoch: epoch,
          ver: ver,
          rel: rel
        )
        case kind
        of depProvides: result.provides.add(dep)
        of depRequires: result.requires.add(dep)
        of depConflicts: result.conflicts.add(dep)
        of depObsoletes: result.obsoletes.add(dep)
        of depEnhances: result.enhances.add(dep)
        of depSuggests: result.suggests.add(dep)
        of depSupplements: result.supplements.add(dep)
        of depRecommends: result.recommends.add(dep)

proc isDir(mode: int): bool =
  (mode and 0xF000) == 0x4000

proc collectFiles(h: Header): seq[tuple[typ: string, path: string]] =
  # Prepare rpmtd objects
  let dirnames = rpmtdNew()
  let dirindexes = rpmtdNew()
  let basenames = rpmtdNew()
  let fileflags = rpmtdNew()
  let filemodes = rpmtdNew()

  defer:
    discard rpmtdFree(dirnames)
    discard rpmtdFree(dirindexes)
    discard rpmtdFree(basenames)
    discard rpmtdFree(fileflags)
    discard rpmtdFree(filemodes)

    # Load tags
  discard headerGet(h, cast[rpmTagVal](RPMTAG_DIRNAMES), dirnames, 0)
  discard headerGet(h, cast[rpmTagVal](RPMTAG_DIRINDEXES), dirindexes, 0)
  discard headerGet(h, cast[rpmTagVal](RPMTAG_BASENAMES), basenames, 0)
  discard headerGet(h, cast[rpmTagVal](RPMTAG_FILEFLAGS), fileflags, 0)
  discard headerGet(h, cast[rpmTagVal](RPMTAG_FILEMODES), filemodes, 0)

  # Build dirnames list
  var dir_list: seq[string]
  discard rpmtdInit(dirnames)
  while rpmtdNext(dirnames) != -1:
    dir_list.add($rpmtdGetString(dirnames))

  # Iterate files
  discard rpmtdInit(basenames)
  discard rpmtdInit(dirindexes)
  discard rpmtdInit(fileflags)
  discard rpmtdInit(filemodes)
  while (rpmtdNext(basenames) != -1 and
          rpmtdNext(dirindexes) != -1 and
          rpmtdNext(fileflags) != -1 and
          rpmtdNext(filemodes) != -1):
    let basename = $rpmtdGetString(basenames)
    let diridx = rpmtdGetNumber(dirindexes).int
    let dirname = if diridx < dir_list.len: dir_list[diridx] else: ""
    let mode = rpmtdGetNumber(filemodes).int
    let flags = rpmtdGetNumber(fileflags).int
    let typ =
      if isDir(mode): "dir"
      elif (flags and RPMFILE_GHOST) != 0: "ghost"
      else: ""
    let path = if dirname.len > 0: dirname & "/" & basename else: basename
    result.add((typ: typ, path: path))

# end is a keyword in nim
proc headerByteRange(path: string): tuple[start, end_z: int64] =
  ## cr_get_header_byte_range
  ## ? https://github.com/rpm-software-management/createrepo_c/blob/master/src/misc.c#L244
  var f = open(path, fmRead)
  defer:
    close f
  f.setFilePos 104
  var bytes: seq[uint8] = @[0, 0]
  if f.readBytes(bytes, 0, 2) != 2:
    raise newException(IOError, "Failed to read header byte range")
  let
    sigindex = htonl(bytes[0]).int64
    sigdata = htonl(bytes[1]).int64
    sigindexsize = sigindex * 16
    sigsize = sigdata + sigindexsize
  var disttoboundary = sigsize mod 8
  if disttoboundary != 0:
    disttoboundary = 8 - disttoboundary
  let hdrstart: int64 = 112 + sigsize + disttoboundary
  f.setFilePos hdrstart
  f.setFilePos(8, fspCur)
  if f.readBytes(bytes, 0, 2) != 2:
    raise newException(IOError, "Failed to read header byte range")
  var
    hdrindex = htonl(bytes[0]).int64
    hdrdata = htonl(bytes[1]).int64
    hdrindexsize = hdrindex * 16
    hdrsize = hdrdata + hdrindexsize + 16
    hdrend = hdrstart + hdrsize
  if hdrend < hdrstart:
    raise newException(
      IOError, fmt"sanity check fail on {path} (hdrend {hdrend} < hdrstart {hdrstart})"
    )
  result.start = hdrstart
  result.end_z = hdrend

proc collectChangelogs(h: Header): seq[Changelog] =
  let changelogtimes = rpmtdNew()
  let changelognames = rpmtdNew()
  let changelogtexts = rpmtdNew()
  defer:
    discard rpmtdFree(changelogtimes)
    discard rpmtdFree(changelognames)
    discard rpmtdFree(changelogtexts)

  if headerGet(h, cast[rpmTagVal](RPMTAG_CHANGELOGTIME), changelogtimes, 0).bool and
      headerGet(h, cast[rpmTagVal](RPMTAG_CHANGELOGNAME), changelognames, 0).bool and
      headerGet(h, cast[rpmTagVal](RPMTAG_CHANGELOGTEXT), changelogtexts, 0).bool:
    discard rpmtdInit(changelogtimes)
    discard rpmtdInit(changelognames)
    discard rpmtdInit(changelogtexts)
    var last_time = 0
    while (rpmtdNext(changelogtimes) != -1 and
            rpmtdNext(changelognames) != -1 and
            rpmtdNext(changelogtexts) != -1):
      var author = $rpmtdGetString(changelognames)
      # Remove trailing spaces from author
      author = author.strip()
      let time = rpmtdGetNumber(changelogtimes).int
      let message = $rpmtdGetString(changelogtexts)
      result.add Changelog(author: author, date: time, message: message)
      # If a previous entry has the same time, increment previous entry's time
      if last_time == time and result.len > 1:
        var tmp_time = time
        var idx = result.len - 2
        while idx >= 0 and result[idx].date == tmp_time:
          inc result[idx].date
          inc tmp_time
          dec idx
      else:
        last_time = time
          
proc rpm*(path: string): Rpm =
  let
    ts = rpmtsCreate()
    abspath = path.Path.absolutePath
    fd = Fopen(abspath.cstring, "r")
  if fd == nil:
    raise newException(IOError, "Failed to open RPM file: " & $abspath)
  defer:
    discard Fclose fd
    discard rpmtsFree ts
  var h = headerNew()
  if rpmReadPackageFile(ts, fd, nil, addr h) != RPMRC_OK:
    raise newException(IOError, "Failed to read RPM header: " & $abspath)
  if cast[pointer](h).isNil:
    raise newException(IOError, "nil header pointer" & $abspath)
  defer:
    discard headerFree(h)

  # 2. Extract fields for PrimaryPkg
  var primary: PrimaryPkg
  primary.name = $headerGetString(h, cast[rpmTagVal](RPMTAG_NAME))
  primary.arch = $headerGetString(h, cast[rpmTagVal](RPMTAG_ARCH))
  primary.epoch = headerGetNumber(h, cast[rpmTagVal](RPMTAG_EPOCH)).int
  primary.ver = $headerGetString(h, cast[rpmTagVal](RPMTAG_VERSION))
  primary.rel = $headerGetString(h, cast[rpmTagVal](RPMTAG_RELEASE))
  primary.summary = $headerGetString(h, cast[rpmTagVal](RPMTAG_SUMMARY))
  primary.description = $headerGetString(h, cast[rpmTagVal](RPMTAG_DESCRIPTION))
  primary.packager = $headerGetString(h, cast[rpmTagVal](RPMTAG_PACKAGER))
  primary.url = $headerGetString(h, cast[rpmTagVal](RPMTAG_URL))
  primary.time.file = headerGetNumber(h, cast[rpmTagVal](RPMTAG_FILEVERIFYFLAGS)).int
  primary.time.build = headerGetNumber(h, cast[rpmTagVal](RPMTAG_BUILDTIME)).int
  primary.size.package = headerGetNumber(h, cast[rpmTagVal](RPMTAG_SIZE)).int
  primary.size.installed = headerGetNumber(h, cast[rpmTagVal](RPMTAG_LONGSIZE)).int
  primary.size.archive = headerGetNumber(h, cast[rpmTagVal](RPMTAG_ARCHIVESIZE)).int
  primary.location = path
  primary.checksum = sha256sum(path)
  primary.format.license = $headerGetString(h, cast[rpmTagVal](RPMTAG_LICENSE))
  primary.format.vendor = $headerGetString(h, cast[rpmTagVal](RPMTAG_VENDOR))
  primary.format.group = $headerGetString(h, cast[rpmTagVal](RPMTAG_GROUP))
  primary.format.buildhost = $headerGetString(h, cast[rpmTagVal](RPMTAG_BUILDHOST))
  primary.format.sourcerpm = $headerGetString(h, cast[rpmTagVal](RPMTAG_SOURCERPM))
  let (start, end_z) = headerByteRange(path)
  primary.format.header_range_start = start.int
  primary.format.header_range_end = end_z.int
  let pcre = collectPCRE(h)
  primary.format.provides = pcre.provides
  primary.format.conflicts = pcre.conflicts
  primary.format.requires = pcre.requires
  primary.format.enhances = pcre.enhances
  primary.format.suggests = pcre.suggests
  primary.format.supplements = pcre.supplements
  primary.format.recommends = pcre.recommends
  primary.format.obsoletes = pcre.obsoletes
  
  # 3. Extract fields for OtherPkg
  var other: OtherPkg
  other.pkgid = primary.checksum
  other.name = primary.name
  other.arch = primary.arch
  other.epoch = primary.epoch
  other.ver = primary.ver
  other.rel = primary.rel
  other.changelogs = collectChangelogs(h)

  # 4. Extract fields for FileListPkg
  var filelist: FileListPkg
  filelist.pkgid = primary.checksum
  filelist.name = primary.name
  filelist.arch = primary.arch
  filelist.epoch = primary.epoch
  filelist.ver = primary.ver
  filelist.rel = primary.rel
  filelist.files = collectFiles(h)

  # 5. Return result
  result = Rpm(primary: primary, other: other, filelist: filelist)
  echo $abspath
