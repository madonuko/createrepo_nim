# Package

version       = "0.1.0"
author        = "madonuko"
description   = "My own faster implementation of rpm createrepo"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["createrepo_nim"]


# Dependencies

requires "nim >= 2.0.0"
requires "cligen"
requires "bingo"
# requires "cattag"
requires "futhark"
