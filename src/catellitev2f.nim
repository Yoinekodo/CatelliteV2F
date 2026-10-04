## Catellite V2F - VRM to FBX converter (Nim reimplementation).
##
## Usage:
##   catellitev2f <input.vrm> <output.fbx>   convert directly
##   catellitev2f                            open the GUI
import std/os
import nimactgui
import core/glb
import convert
import fbxexport
import gui

proc convertFile(vrmPath, fbxPath: string): string =
  let data = readFile(vrmPath)
  var bytes = newSeq[byte](data.len)
  for i, ch in data: bytes[i] = byte(ord(ch))
  let g = parseGltf(bytes)
  ensureOutputDir(fbxPath)
  # Blender puts the textures in a <fbx name>.fbm folder next to the FBX.
  let scene = buildScene(g, fbmDirFor(fbxPath))
  result = exportScene(scene, fbxPath)
  discard scene.writeTextureFolder()

when isMainModule:
  # Built with `--app:gui`, so there is no console window when the exe is
  # double-clicked.  Messages therefore go to a message box instead of stdout.
  let args = commandLineParams()
  if args.len >= 2:
    try:
      discard convertFile(args[0], args[1])
    except CatchableError as e:
      alert("Error: " & e.msg, "Catellite V2F", isError = true)
      quit(1)
  else:
    runGui()
