# Package

version       = "1.0.0"
author        = "Yoinekodo"
description   = "VRM to FBX converter (Nim reimplementation of CatelliteV2F)"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["catellitev2f"]

requires "nim >= 2.0.0"

# Keep icon.res in step with icon.ico.
#
# config.nims links the icon with `--passL:"icon.res"`, which is one of the few
# link options a config.nims is allowed to carry, so the .res has to exist before
# the compiler runs. Without this hook a changed icon.ico would keep linking the
# previous artwork - or fail the link outright on a fresh checkout.
#
# The script warns rather than fails when windres is missing, because a slightly
# stale icon is not worth failing a build over.
before build:
  exec("powershell -NoProfile -ExecutionPolicy Bypass -File tools/build_icon.ps1")