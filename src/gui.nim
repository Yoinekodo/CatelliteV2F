## Catellite V2F - windowed front end, built on nimact's GUI toolkit.
##
## The shape of it is nimact's model: `build()` is re-evaluated every frame, so
## plain fields on `UiState` *are* the component state and the UI is a pure
## function of them.  The only thing that is not frame-local is the conversion
## itself, which runs on a worker thread and publishes through nimact's
## `Progress` plus a lock-guarded log buffer.
##
## Both required build settings live in `config.nims`: `--app:gui`, so there is no
## console window, and `--mm:arc`, so the worker thread and the UI thread share one
## heap. Under `refc` the worker's pages are released when the thread exits, which
## is a latent crash rather than an obvious one - see the note in `config.nims`.
import std/[os, strutils, locks]
import nimactgui

import core/glb
import convert
import fbxexport
import appicon

let
  vrmFilters = @[FileFilter(desc: "VRM", pattern: "*.vrm"),
                 FileFilter(desc: "glTF binary", pattern: "*.glb"),
                 FileFilter(desc: "All files", pattern: "*.*")]
  fbxFilters = @[FileFilter(desc: "FBX", pattern: "*.fbx"),
                 FileFilter(desc: "All files", pattern: "*.*")]

type
  StatusKind = enum
    skIdle, skOk, skError

  Job = ref object
    ## Hand-off to the worker.  Held in a module-level global so the collector
    ## cannot reclaim it while the thread is still reading through it.
    vrmPath, fbxPath: string
    progress: Progress
    logLock: Lock
    lines: seq[string]
    wrote: string        ## output path once the FBX is on disk

  UiState = ref object
    app: GuiApp
    vrmField: TextFieldState
    fbxField: TextFieldState
    logField: TextFieldState
    job: Job
    status: string
    statusKind: StatusKind

proc defaultOutput*(vrmPath: string): string =
  ## `model.vrm` next to the source becomes `model.fbx`, which is what picking a
  ## VRM should imply.
  let parts = vrmPath.splitFile
  parts.dir / parts.name.changeFileExt(".fbx")

proc startJob(st: UiState)   ## forward: the view's Convert button refers to it

var gJob: Job           ## keeps the job alive across frames

# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

proc jlog(job: Job, s: string) =
  acquire(job.logLock)
  job.lines.add s
  release(job.logLock)

proc stage(p: Progress, v: float32, msg: string): bool =
  ## Publishes a stage and reports whether the job should keep going.
  p.setValue(v)
  p.setLabel(msg)
  p.setDetail("")
  not p.isCancelled

proc convertJob(job: Job) =
  ## The conversion itself, as a plain proc.
  ##
  ## No `{.thread.}` and no `{.gcsafe.}`: `runJob` does the cast at the one place
  ## that actually crosses the thread boundary, so the pipeline stays ordinary
  ## Nim. Everything it touches is either thread-local or explicitly shared -
  ## `Progress` for anything the UI reads, and `job.lines` under `logLock`.
  let p = job.progress
  try:
    if not stage(p, 0.05f32, "Reading " & job.vrmPath.extractFilename):
      p.setLabel("Cancelled"); p.finish(); return

    let data = readFile(job.vrmPath)
    var bytes = newSeq[byte](data.len)
    for i, ch in data: bytes[i] = byte(ord(ch))
    if not stage(p, 0.25f32, "Parsing glTF / VRM"):
      p.setLabel("Cancelled"); p.finish(); return
    let g = parseGltf(bytes)

    if not stage(p, 0.40f32, "Building scene (bones, T-pose, visemes)"):
      p.setLabel("Cancelled"); p.finish(); return
    ensureOutputDir(job.fbxPath)
    # Blender puts the textures in a <fbx name>.fbm folder next to the FBX.
    let scene = buildScene(g, fbmDirFor(job.fbxPath))

    if not stage(p, 0.70f32, "Writing FBX"):
      p.setLabel("Cancelled"); p.finish(); return
    p.setDetail(job.fbxPath.extractFilename)
    discard exportScene(scene, job.fbxPath)

    if not stage(p, 0.92f32, "Writing texture folder"):
      p.setLabel("Cancelled"); p.finish(); return
    discard scene.writeTextureFolder()

    job.wrote = job.fbxPath
    jlog(job, "Done: " & job.fbxPath)
    p.setValue(1.0f32)
    p.setLabel("Finished")
    p.setDetail("")
    # `finish` stores an atomic, so the plain writes above (`wrote`, and the
    # locked log lines) are visible to any thread that reads `isDone` and sees
    # it set. Publishing them after `finish` would race.
    p.finish()
  except CatchableError as e:
    jlog(job, "Error: " & e.msg)
    p.setError(e.msg)
    p.finish()

# ---------------------------------------------------------------------------
# UI pieces
# ---------------------------------------------------------------------------

proc pathField(label, value: string, field: TextFieldState,
               placeholder: string, tabIndex: int, onBrowse: proc()): Widget =
  card(
    padding = all(16), radius = 14,
    color = colSurface, borderColor = colBorder, borderWidth = 1,
    shadow = boxShadow(blur = 18, dy = 5, opacity = 0.22),
    child = column(ws(
        text(label, 12, colTextMuted, fwSemiBold),
        row(ws(
            expanded(textField(value, TextFieldOpts(
                        placeholder: placeholder, mono: true, size: 14,
                        state: field, tabOrder: tabIndex))),
            button("Browse...", style = buttonStyle(
                      bg = colSurfaceHi, fg = colText,
                      hoverBg = colBorder, radius = 9,
                      padding = all(10, 16), size = 13),
                   onTap = onBrowse)),
            space = 10, crossAlign = caCenter)),
        space = 8))

proc logCard(st: UiState): Widget =
  # `std/strutils.splitLines` has to be spelled out: nimact's text module exports
  # a `splitLines` of its own for wrapping, and both are in scope here.
  let lines = strutils.splitLines(st.logField.text)
  card(
    padding = all(16), radius = 14,
    color = colSurface, borderColor = colBorder, borderWidth = 1,
    child = column(ws(
        row(ws(
            text("Log", 12, colTextMuted, fwSemiBold),
            text($lines.len & (if lines.len == 1: " line" else: " lines"),
                 11, colTextMuted)),
            mainAlign = maSpaceBetween),
        # `expanded` hands its child the card's width and the leftover height, and
        # `console` paints itself over whatever rect it is given (it does its own
        # multi-line scrolling and pins to the newest line). Wrapping it in
        # `scrollable` would *shrink* it again: a scroll view deliberately paints
        # its child at the child's measured size, and a text field measures to
        # its text.
        expanded(console(st.logField.text, st.logField,
                         mono = true, size = 12.5, bg = colBgElevated))),
      space = 10))

proc statusColor(st: UiState): Color =
  case st.statusKind
  of skOk: colSuccess
  of skError: colDanger
  else: colTextDim

proc actionBar(st: UiState, start: proc()): Widget =
  let job = st.job
  let busy = job != nil and not job.progress.isDone
  let ready = st.vrmField.text.len > 0 and st.fbxField.text.len > 0
  # The finished-but-not-yet-dismissed case: the file is on disk and the log has
  # the path, so the status line offers to open it rather than making the user
  # retype the path.
  let justDone = job != nil and job.progress.isDone and job.wrote.len > 0
  column(ws(
      row(ws(
          button(if busy: "Converting..." else: "Convert",
                 style = buttonStyle(bg = colPrimary, hoverBg = colPrimaryHi,
                                     radius = 10, padding = all(12, 22),
                                     shadow = boxShadow(blur = 16, dy = 4,
                                                        opacity = 0.30)),
                 enabled = (not busy) and ready,
                 onTap = (if busy or not ready: nil else: start)),
          # Cancellation is cooperative and only checked between stages, so a
          # press during "Writing FBX" still lets that file finish - which is
          # what we want, since a half-written FBX is worse than a late one.
          (if busy:
             button("Cancel",
                    style = buttonStyle(bg = colSurfaceHi, fg = colTextDim,
                                        hoverBg = colBorder, radius = 10,
                                        padding = all(12, 18), size = 13),
                    onTap = proc() = job.progress.cancel())
           elif justDone:
             button("Open folder",
                    style = buttonStyle(bg = colSurfaceHi, fg = colText,
                                        hoverBg = colBorder, radius = 10,
                                        padding = all(12, 18), size = 13),
                    onTap = proc() =
                      if not revealInExplorer(job.wrote, st.app.hwnd):
                        st.status = "Could not open the folder."
                        st.statusKind = skError)
           else:
             sizedBox(width = 1, height = 1)),
          spacer(1),
          (if st.status.len > 0:
             text(st.status, 13, statusColor(st), fwMedium)
           else:
             text("Drop a .vrm here, or browse for one.",
                  13, colTextMuted))),
          space = 14, crossAlign = caCenter),
      (if busy:
         # The stage name, with the file being written underneath it: a 12 MB
         # write is long enough that "Writing FBX" alone leaves the user
         # guessing which of several queued models this is.
         column(ws(
             progressBar(job.progress.value(), color = colPrimary,
                         trackColor = colSurfaceHi, height = 8, radius = 4),
             text(if job.progress.detail.len > 0:
                    job.progress.label & "  " & job.progress.detail
                  else:
                    job.progress.label, 12, colTextMuted)),
             space = 6)
       elif st.app.tasks.busy:
         # `Progress` says how far along a job with stages is. This is the other
         # case: something is running that cannot report a fraction.
         row(ws(spinner(15), text("Working...", 12, colTextMuted)),
             space = 8, crossAlign = caCenter)
       else:
         sizedBox(height = 4))),
      space = 10)

proc buildUi(st: UiState): Widget =
  scaffold(
    appBar = appBar("Catellite V2F", subtitle = "VRM to FBX  ·  VRChat ready",
                    height = 62, bg = colBgElevated),
    content = padding(
      sizedBox(
        column(ws(
            pathField("Source VRM", st.vrmField.text, st.vrmField,
                      "C:\\path\\to\\model.vrm", 1,
                      proc() =
                        let p = pickFile("Select VRM to convert", "",
                                         vrmFilters)
                        if p.len > 0:
                          st.vrmField.text = p
                          st.vrmField.caret = p.len
                          st.fbxField.text = defaultOutput(p)
                          st.fbxField.caret = st.fbxField.text.len),
            pathField("Output FBX", st.fbxField.text, st.fbxField,
                      "C:\\path\\to\\model.fbx", 2,
                      proc() =
                        # nimact's `dialogs.parentDir` and `std/os`'s are both in scope and both take a
                        # string, so the intended one has to be named.
                        let p = pickSaveFile("Save FBX as",
                                             st.fbxField.text.extractFilename,
                                             dialogs.parentDir(
                                               st.fbxField.text),
                                             fbxFilters)
                        if p.len > 0:
                          st.fbxField.text = p
                          st.fbxField.caret = p.len),
            actionBar(st, proc() = startJob(st)),
            expanded(logCard(st))),
          space = 16),
        width = 760),
      all(22)))

# ---------------------------------------------------------------------------
# Job control (UI thread)
# ---------------------------------------------------------------------------

proc drainLog(st: UiState) =
  if st.job == nil: return
  acquire(st.job.logLock)
  let pending = move(st.job.lines)
  release(st.job.logLock)
  if pending.len == 0: return
  var buf = st.logField.text
  if buf.len > 0 and buf[^1] != '\n': buf.add '\n'
  for l in pending:
    buf.add l
    buf.add '\n'
  st.logField.text = buf
  st.logField.caret = buf.len

proc startJob(st: UiState) =
  let vrm = st.vrmField.text.strip()
  let fbx = st.fbxField.text.strip()
  if vrm.len == 0 or fbx.len == 0:
    st.status = "Pick a VRM and an output path first."
    st.statusKind = skError
    return
  if not fileExists(vrm):
    st.status = "VRM not found."
    st.statusKind = skError
    return

  # The header goes straight into the field, not into `job.lines`: the worker's
  # first flush would otherwise append a second copy of it.
  st.job = Job(vrmPath: vrm, fbxPath: fbx, progress: newProgress("Starting"),
               lines: @[], wrote: "")
  initLock(st.job.logLock)
  gJob = st.job
  st.logField.text = "Converting " & vrm & "\n  ->  " & fbx & "\n"
  st.logField.caret = st.logField.text.len
  st.status = "Working..."
  st.statusKind = skIdle
  st.job.progress.clear()
  # `runJob` takes a plain closure, so there is no handle to keep alive and no
  # annotation on `convertJob`. It also decrements the queue's own `active`
  # count when the closure returns, so `busy` goes false on its own.
  let job = st.job
  st.app.tasks.runJob(proc() = convertJob(job))

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc runGui*() =
  var st = UiState(
    vrmField: initField(""),
    fbxField: initField(""),
    logField: initField(""),
    status: "",
    statusKind: skIdle)

  let app = newGuiApp("Catellite V2F", 860, 760)
  st.app = app
  # The window class carries no icon, so the title bar would show the default
  # application icon until this runs. The executable's own icon (Explorer, taskbar)
  # comes from `--win32icon` and is already there.
  appicon.setAppIcon(app.hwnd)

  app.onUpdate = proc(dt: float32) =
    discard dt
    # Drag and drop. `takeDropped` drains, so a drop is handled once instead of
    # on every subsequent frame.
    for p in app.takeDropped():
      let ext = p.splitFile.ext.toLowerAscii
      if ext == ".vrm" or ext == ".glb":
        st.vrmField.text = p
        st.vrmField.caret = p.len
        st.fbxField.text = defaultOutput(p)
        st.fbxField.caret = st.fbxField.text.len
        st.status = "Loaded " & p.extractFilename
        st.statusKind = skIdle
        break

    if st.job != nil:
      drainLog(st)
      let p = st.job.progress
      if p.isDone:
        # Three ways a job ends, and `finish` is called on all of them, so the
        # progress object alone cannot tell them apart. Treating "done with
        # nothing written and no error" as still-running would leave the Convert
        # button stuck on "Converting..." after a cancel.
        if st.job.wrote.len > 0:
          let size = getFileSize(st.job.wrote)
          st.status = "Wrote " & st.job.wrote.extractFilename &
                      "  (" & $(size div 1024) & " KB)"
          st.statusKind = skOk
          # `st.job` is deliberately kept: `actionBar` reads `wrote` from it to
          # offer "Open folder" on the finished file, and `isDone` is already
          # true so nothing else treats this as running. `startJob` replaces it.
        elif p.errorText.len > 0:
          st.status = p.errorText
          st.statusKind = skError
          st.job = nil
        else:
          st.status = "Cancelled."
          st.statusKind = skIdle
          st.job = nil

    # A worker that raised something the queue caught: `runJob` routes it here
    # rather than letting it kill the process. Our own `convertJob` handles its
    # errors, so this is the backstop for a failure outside that try block.
    for msg in app.tasks.takeErrors():
      st.status = msg
      st.statusKind = skError
      st.job = nil

  app.onKey = proc(k: GuiKey) =
    if k.kind == gkEscape:
      app.quit()
    elif k.kind == gkEnter and not (st.job != nil and
                                    not st.job.progress.isDone):
      startJob(st)

  app.onClose = proc() =
    # If a conversion is still in flight, closing the window means throwing away
    # a file that is half written. Ask instead - and only that: if nothing is
    # running, close without a dialog box appearing for no reason.
    if app.tasks.busy and
       confirm("A conversion is still running.\n\n" &
               "Closing now will leave the output file incomplete. Close anyway?",
               "Catellite V2F", danger = true):
      app.quit()

  app.run(proc(): Widget = buildUi(st))