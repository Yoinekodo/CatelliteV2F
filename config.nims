# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Windows GUI subsystem, not console.
#
# Double-clicking the exe should open a window, not a console that stays open
# behind it. Lives here rather than on the command line so `nimble build` gets it
# too - the nimble file has no way to pass `--app` through, and without this
# `nimble build` silently produced a console-subsystem binary.
--app:"gui"

# Application icon, embedded in the executable.
#
# `--win32icon` would do this in one step but is not accepted in config.nims -
# only a small subset of options is allowed there - and the nimble file has no
# way to pass it through either, so `nimble build` would produce an exe with no
# icon at all. `icon.res` is the .ico compiled to a linkable object (see icon.rc),
# and `--passL` *is* allowed here, so both build paths get the icon.
#
# Relative to the project directory, which is what both `nimble build` and a bare
# `nim c` use. Regenerate it after changing icon.ico: `tools\build_icon.ps1`, or
# just `nimble build`, which does it when icon.ico is newer.
--passL:"icon.res"

# Memory manager.
#
# `arc` rather than the `-d:release` default of `orc`, because the GUI runs the
# conversion on a worker thread (nimact/gui/async.nim) and the whole pipeline
# allocates while it runs. Every thread has to share one heap, or a sequence
# allocated on the worker is gone by the time the UI thread reads it.
#
# nimact measured all three on this toolchain (Nim 2.2.12, MinGW, Windows) with
# a worker that builds a `seq[string]` and hands it back through a `uint`
# handle: `arc` reads back correctly, `refc` faults on the first read because
# the worker's pages are released when the thread exits, and `orc` happens to
# work but documents its heaps as thread-local. `arc` is the one Nim implements
# with a single shared, lock-guarded heap under `--threads:on`.
#
# This was `refc` before, on the belief that refc is the shared-heap manager.
# That is exactly backwards - see nimact's async.nim for the measurement.
--mm:"arc"