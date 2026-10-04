## The application icon, in the two places Windows keeps it.
##
## There are two of them and neither fills in the other:
##
## 1. **The executable's icon resource**, set by `--win32icon` in `config.nims`.
##    Explorer, the taskbar button, the file's properties sheet and the Add/
##    Remove Programs entry all read this, and they read it without the process
##    ever running.
##
## 2. **The window's icon**, which is what the title bar and the Alt-Tab switcher
##    draw. nimact's window class registers no `hIcon`, so without this the
##    title bar shows the default application icon even though the exe has a
##    perfectly good one. There is no nimact API for it - `newGuiApp` takes no
##    icon and the class is registered once, globally - so it is set here with
##    `WM_SETICON` after the window exists.
##
## The handles are read out of the running executable's own resource rather than
## from a file on disk, so a copied or installed exe shows the right icon with no
## extra file to ship and no dependency on the working directory. Loading from
## the resource needs a fixed resource id, which is what `--win32icon` produces;
## if that ever fails to resolve, `icon.ico` next to the exe is used instead.
import std/[os, unicode]
import nimactgui          ## HWND, HINSTANCE, UINT, WPARAM, LPARAM, LRESULT

type
  HICON = pointer
  ## Deliberately local: nimact declares one too, but does not export it, and
  ## importing `nimact/gui/win32` for a single pointer type would tie this file
  ## to nimact's internals rather than its API.

const
  WM_GETICON  = 0x007F'u32
  WM_SETICON  = 0x0080'u32
  ICON_SMALL  = 0'u32
  ICON_BIG    = 1'u32
  ICON_SMALL2 = 2'u32      ## the "small icon in a large title bar" slot
  IMAGE_ICON  = 1'u32
  LR_DEFAULTSIZE = 0x0040'u32

  ## `--win32icon` puts the .ico in as the first icon resource, so its id is 1.
  ## MAKEINTRESOURCE is just "the pointer whose value is the id".
  ICON_RESOURCE_ID = 1

  ICON_FILE = "icon.ico"

proc GetModuleHandleW(lpModuleName: pointer): HINSTANCE
  {.importc: "GetModuleHandleW", dynlib: "kernel32.dll".}
proc LoadImageW(hinst: HINSTANCE, lpName: pointer, uType: UINT,
                cxDesired, cyDesired: int32, fuLoad: UINT): HICON
  {.importc: "LoadImageW", dynlib: "user32.dll".}
proc SendMessageW(hWnd: HWND, uMsg: UINT, wParam: WPARAM,
                  lParam: LPARAM): LRESULT
  {.importc: "SendMessageW", dynlib: "user32.dll".}

proc loadFromResource(hinst: HINSTANCE, cx, cy: int32): HICON =
  ## LoadImage resolves an integer resource name as a MAKEINTRESOURCE pointer.
  LoadImageW(hinst, cast[pointer](uint(ICON_RESOURCE_ID)), IMAGE_ICON,
             cx, cy, LR_DEFAULTSIZE)

proc loadFromDisk(cx, cy: int32): HICON =
  ## `LoadImageW` takes a `WCHAR*` path, so the Nim string has to be widened
  ## first; handing it the UTF-8 bytes would be read as nonsense.
  let path = getAppDir() / ICON_FILE
  if not fileExists(path): return nil
  var units = newSeq[uint16](path.len + 1)
  var n = 0
  for r in path.toRunes:
    let cp = uint32(r)
    if cp >= 0x10000'u32:
      let v = cp - 0x10000'u32
      units[n] = uint16(0xD800 + (v shr 10)); inc n
      units[n] = uint16(0xDC00 + (v and 0x3FF'u32))
    else:
      units[n] = uint16(cp)
    inc n
  units[n] = 0'u16
  result = LoadImageW(nil, cast[pointer](addr units[0]), IMAGE_ICON,
                      cx, cy, LR_DEFAULTSIZE)

proc applyIcon(hwnd: HWND, which: UINT, cx, cy: int32) =
  ## One size for one slot. Requesting them separately rather than reusing a
  ## handle keeps the title bar from resampling a 256x256 image every repaint,
  ## which is what the shell would otherwise do at small sizes.
  let hinst = GetModuleHandleW(nil)
  var icon = loadFromResource(hinst, cx, cy)
  if icon == nil:
    icon = loadFromDisk(cx, cy)
  if icon == nil: return
  discard SendMessageW(hwnd, WM_SETICON, WPARAM(which), LPARAM(cast[uint](icon)))

proc setAppIcon*(hwnd: HWND) =
  ## Fills all three icon slots. `WM_SETICON` returns the previous icon, which is
  ## left alone: it belongs to the window class, and nimact shares one class
  ## registration between every `GuiApp`, so destroying it could pull the icon out
  ## from under another window.
  if hwnd == nil: return
  applyIcon(hwnd, ICON_BIG, 32, 32)
  applyIcon(hwnd, ICON_SMALL, 16, 16)
  applyIcon(hwnd, ICON_SMALL2, 24, 24)