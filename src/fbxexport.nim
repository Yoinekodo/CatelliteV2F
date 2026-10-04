## Writes a converted scene as a binary FBX file, mirroring the element layout
## produced by Blender's FBX exporter for the same settings.
import std/[tables, sets, strutils, times]
import times as tms
import ./core/m3
import ./core/fbxw
import ./convert

const
  FbxVersion = 7400'u32
  ModelVersion = 232
  GeometryVersion = 124
  NodeAttrVersion = 100
  DeformerVersion = 100
  ClusterVersion = 100
  SkinVersion = 101
  PoseVersion = 100
  MaterialVersion = 102
  TextureVersion = 202
  TemplatesVersion = 100

type
  Ids = object
    used: Table[int64, bool]
    byKey: Table[string, int64]

proc newIds(): Ids =
  Ids(used: initTable[int64, bool](), byKey: initTable[string, int64]())

proc hashKey(key: string): int64 =
  ## Deterministic stand-in for the exporter's internal uuid hash.
  var h: uint64 = 1469598103934665603'u64
  for ch in key:
    h = (h xor uint64(ord(ch))) * 1099511628211'u64
  h = h xor (h shr 33)
  h = h * 0xff51afd7ed558ccd'u64
  h = h xor (h shr 33)
  var v = int64(h and 0x7FFFFFFFFFFFFFFFu64)
  if v > 1000000000: v = v mod 1000000000
  v

proc getId(ids: var Ids, key: string): int64 =
  ## Stable id per key: the same key always yields the same value, and
  ## collisions with an already issued id are resolved by linear probing.
  if ids.byKey.hasKey(key): return ids.byKey[key]
  var v = hashKey(key)
  while ids.used.hasKey(v):
    inc v
  ids.used[v] = true
  ids.byKey[key] = v
  v

proc fbName(name, cls: string): string = name & "\x00\x01" & cls

# --- property helpers ------------------------------------------------------

proc propStr(n: Node, name, value: string) =
  let e = elem(n, name)
  e.addString(value)

proc propI32(n: Node, name: string, v: int) =
  let e = elem(n, name)
  e.addInt32(int32(v))

proc propI64(n: Node, name: string, v: int64) =
  let e = elem(n, name)
  e.addInt64(v)

proc propTime(n: Node, name: string, v: int64) =
  let e = elem(n, name)
  e.addInt64(v)

proc propF64(n: Node, name: string, v: float64) =
  let e = elem(n, name)
  e.addFloat64(v)

proc propD(n: Node, name: string, v: seq[float64]) =
  let e = elem(n, name)
  e.addFloat64Array(v)

proc propI32Arr(n: Node, name: string, v: seq[int32]) =
  let e = elem(n, name)
  e.addInt32Array(v)

proc propP(p: Node, name, typ, sub, flags: string, vals: seq[string]) =
  let e = elem(p, "P")
  e.addString(name)
  e.addString(typ)
  e.addString(sub)
  e.addString(flags)
  for v in vals: e.addString(v)

proc propPD(p: Node, name, typ, sub, flags: string, vals: seq[float64]) =
  let e = elem(p, "P")
  e.addString(name)
  e.addString(typ)
  e.addString(sub)
  e.addString(flags)
  for v in vals: e.addFloat64(v)

proc propPB(p: Node, name, typ, sub, flags: string, v: bool) =
  let e = elem(p, "P")
  e.addString(name)
  e.addString(typ)
  e.addString(sub)
  e.addString(flags)
  e.addInt32(int32(if v: 1 else: 0))

proc propPI(p: Node, name, typ, sub, flags: string, v: int) =
  let e = elem(p, "P")
  e.addString(name)
  e.addString(typ)
  e.addString(sub)
  e.addString(flags)
  e.addInt32(int32(v))

proc propPI64(p: Node, name, typ, sub, flags: string, v: int64) =
  let e = elem(p, "P")
  e.addString(name)
  e.addString(typ)
  e.addString(sub)
  e.addString(flags)
  e.addInt64(v)

proc mat4Array(m: Mat4): seq[float64] =
  ## FBX serialises matrices row major with the translation in the last row,
  ## i.e. the transpose of the column-vector matrices used internally.
  result = newSeq[float64](16)
  for i in 0..3:
    for j in 0..3:
      result[i * 4 + j] = m[j][i]

# ---------------------------------------------------------------------------
# Property templates (`Definitions/ObjectType/PropertyTemplate`) for the object
# types Blender emits a template for.  Each row is
# (name, type, subtype, flags, values).

type
  ## How a template property's value is encoded.
  TmplValKind = enum
    tvFloat,   ## 'D' float64
    tvInt,     ## 'I' int32 (bool, int, enum, visibility inheritance)
    tvLong,    ## 'L' int64 (KTime)
    tvString,  ## 'S' string
    tvNone     ## type only, no value at all (`p_object`)

  TmplRow = object
    name, typ, sub, flags: string
    kind: TmplValKind
    vals: seq[float64]
    text: string

template tf(nm, ty, sb, fl: static[string], vs: static[array]): TmplRow =
  block:
    var r = TmplRow(name: nm, typ: ty, sub: sb, flags: fl, kind: tvFloat)
    for v in vs: r.vals.add(v)
    r

template ti(nm, ty, sb, fl: static[string], v: static[float64]): TmplRow =
  TmplRow(name: nm, typ: ty, sub: sb, flags: fl, kind: tvInt, vals: @[v])

template ti64(nm, ty, sb, fl: static[string], v: static[float64]): TmplRow =
  TmplRow(name: nm, typ: ty, sub: sb, flags: fl, kind: tvLong, vals: @[v])

template tn(nm, ty, sb, fl: static[string]): TmplRow =
  TmplRow(name: nm, typ: ty, sub: sb, flags: fl, kind: tvNone)

## Shorthands keeping the tables below readable.
template T3(nm, ty, sb, fl: static[string], a, b, c: static[float64]): TmplRow =
  TmplRow(name: nm, typ: ty, sub: sb, flags: fl, kind: tvFloat, vals: @[a, b, c])

template TS(nm, ty, sb, fl: static[string], t: static[string]): TmplRow =
  TmplRow(name: nm, typ: ty, sub: sb, flags: fl, kind: tvString, text: t)

const
  TmplGeometry: seq[TmplRow] = @[
    T3("Color", "ColorRGB", "Color", "", 0.8, 0.8, 0.8),
    T3("BBoxMin", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("BBoxMax", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    ti("Primary Visibility", "bool", "", "", 1.0),
    ti("Casts Shadows", "bool", "", "", 1.0),
    ti("Receive Shadows", "bool", "", "", 1.0)]

  TmplModel: seq[TmplRow] = @[
    ti("QuaternionInterpolate", "enum", "", "", 0.0),
    T3("RotationOffset", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("RotationPivot", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("ScalingOffset", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("ScalingPivot", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    ti("TranslationActive", "bool", "", "", 0.0),
    T3("TranslationMin", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("TranslationMax", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    ti("TranslationMinX", "bool", "", "", 0.0),
    ti("TranslationMinY", "bool", "", "", 0.0),
    ti("TranslationMinZ", "bool", "", "", 0.0),
    ti("TranslationMaxX", "bool", "", "", 0.0),
    ti("TranslationMaxY", "bool", "", "", 0.0),
    ti("TranslationMaxZ", "bool", "", "", 0.0),
    ti("RotationOrder", "enum", "", "", 0.0),
    ti("RotationSpaceForLimitOnly", "bool", "", "", 0.0),
    tf("RotationStiffnessX", "double", "Number", "", [0.0]),
    tf("RotationStiffnessY", "double", "Number", "", [0.0]),
    tf("RotationStiffnessZ", "double", "Number", "", [0.0]),
    tf("AxisLen", "double", "Number", "", [10.0]),
    T3("PreRotation", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("PostRotation", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    ti("RotationActive", "bool", "", "", 0.0),
    T3("RotationMin", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("RotationMax", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    ti("RotationMinX", "bool", "", "", 0.0),
    ti("RotationMinY", "bool", "", "", 0.0),
    ti("RotationMinZ", "bool", "", "", 0.0),
    ti("RotationMaxX", "bool", "", "", 0.0),
    ti("RotationMaxY", "bool", "", "", 0.0),
    ti("RotationMaxZ", "bool", "", "", 0.0),
    ti("InheritType", "enum", "", "", 0.0),
    ti("ScalingActive", "bool", "", "", 0.0),
    T3("ScalingMin", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("ScalingMax", "Vector3D", "Vector", "", 1.0, 1.0, 1.0),
    ti("ScalingMinX", "bool", "", "", 0.0),
    ti("ScalingMinY", "bool", "", "", 0.0),
    ti("ScalingMinZ", "bool", "", "", 0.0),
    ti("ScalingMaxX", "bool", "", "", 0.0),
    ti("ScalingMaxY", "bool", "", "", 0.0),
    ti("ScalingMaxZ", "bool", "", "", 0.0),
    T3("GeometricTranslation", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("GeometricRotation", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("GeometricScaling", "Vector3D", "Vector", "", 1.0, 1.0, 1.0),
    tf("MinDampRangeX", "double", "Number", "", [0.0]),
    tf("MinDampRangeY", "double", "Number", "", [0.0]),
    tf("MinDampRangeZ", "double", "Number", "", [0.0]),
    tf("MaxDampRangeX", "double", "Number", "", [0.0]),
    tf("MaxDampRangeY", "double", "Number", "", [0.0]),
    tf("MaxDampRangeZ", "double", "Number", "", [0.0]),
    tf("MinDampStrengthX", "double", "Number", "", [0.0]),
    tf("MinDampStrengthY", "double", "Number", "", [0.0]),
    tf("MinDampStrengthZ", "double", "Number", "", [0.0]),
    tf("MaxDampStrengthX", "double", "Number", "", [0.0]),
    tf("MaxDampStrengthY", "double", "Number", "", [0.0]),
    tf("MaxDampStrengthZ", "double", "Number", "", [0.0]),
    tf("PreferedAngleX", "double", "Number", "", [0.0]),
    tf("PreferedAngleY", "double", "Number", "", [0.0]),
    tf("PreferedAngleZ", "double", "Number", "", [0.0]),
    ti("Show", "bool", "", "", 1.0),
    tn("LookAtProperty", "object", "", ""),
    tn("UpVectorProperty", "object", "", ""),
    ti("NegativePercentShapeSupport", "bool", "", "", 1.0),
    ti("DefaultAttributeIndex", "int", "Integer", "", -1.0),
    ti("Freeze", "bool", "", "", 0.0),
    ti("LODBox", "bool", "", "", 0.0),
    T3("Lcl Translation", "Lcl Translation", "", "A", 0.0, 0.0, 0.0),
    T3("Lcl Rotation", "Lcl Rotation", "", "A", 0.0, 0.0, 0.0),
    T3("Lcl Scaling", "Lcl Scaling", "", "A", 1.0, 1.0, 1.0),
    tf("Visibility", "Visibility", "", "A", [1.0]),
    ti("Visibility Inheritance", "Visibility Inheritance", "", "", 1.0)]

  TmplMaterial: seq[TmplRow] = @[
    TS("ShadingModel", "KString", "", "", "Phong"),
    ti("MultiLayer", "bool", "", "", 0.0),
    T3("EmissiveColor", "Color", "", "A", 0.0, 0.0, 0.0),
    tf("EmissiveFactor", "Number", "", "A", [1.0]),
    T3("AmbientColor", "Color", "", "A", 0.2, 0.2, 0.2),
    tf("AmbientFactor", "Number", "", "A", [1.0]),
    T3("DiffuseColor", "Color", "", "A", 0.8, 0.8, 0.8),
    tf("DiffuseFactor", "Number", "", "A", [1.0]),
    T3("TransparentColor", "Color", "", "A", 0.0, 0.0, 0.0),
    tf("TransparencyFactor", "Number", "", "A", [0.0]),
    tf("Opacity", "Number", "", "A", [1.0]),
    T3("NormalMap", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("Bump", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    tf("BumpFactor", "double", "Number", "", [1.0]),
    T3("DisplacementColor", "ColorRGB", "Color", "", 0.0, 0.0, 0.0),
    tf("DisplacementFactor", "double", "Number", "", [1.0]),
    T3("VectorDisplacementColor", "ColorRGB", "Color", "", 0.0, 0.0, 0.0),
    tf("VectorDisplacementFactor", "double", "Number", "", [1.0]),
    T3("SpecularColor", "Color", "", "A", 0.2, 0.2, 0.2),
    tf("SpecularFactor", "Number", "", "A", [1.0]),
    tf("Shininess", "Number", "", "A", [20.0]),
    tf("ShininessExponent", "Number", "", "A", [20.0]),
    T3("ReflectionColor", "Color", "", "A", 0.0, 0.0, 0.0),
    tf("ReflectionFactor", "Number", "", "A", [1.0])]

  TmplTexture: seq[TmplRow] = @[
    ti("TextureTypeUse", "enum", "", "", 0.0),
    ti("AlphaSource", "enum", "", "", 2.0),
    tf("Texture alpha", "double", "Number", "", [1.0]),
    ti("PremultiplyAlpha", "bool", "", "", 1.0),
    ti("CurrentTextureBlendMode", "enum", "", "", 1.0),
    ti("CurrentMappingType", "enum", "", "", 0.0),
    TS("UVSet", "KString", "", "", "default"),
    ti("WrapModeU", "enum", "", "", 0.0),
    ti("WrapModeV", "enum", "", "", 0.0),
    ti("UVSwap", "bool", "", "", 0.0),
    T3("Translation", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("Rotation", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("Scaling", "Vector3D", "Vector", "", 1.0, 1.0, 1.0),
    T3("TextureRotationPivot", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    T3("TextureScalingPivot", "Vector3D", "Vector", "", 0.0, 0.0, 0.0),
    ti("UseMaterial", "bool", "", "", 0.0),
    ti("UseMipMap", "bool", "", "", 0.0)]

  TmplVideo: seq[TmplRow] = @[
    ti("Width", "int", "Integer", "", 0.0),
    ti("Height", "int", "Integer", "", 0.0),
    TS("Path", "KString", "Url", "", ""),
    ti("AccessMode", "enum", "", "", 0.0),
    ti("StartFrame", "int", "Integer", "", 0.0),
    ti("StopFrame", "int", "Integer", "", 0.0),
    ti64("Offset", "KTime", "Time", "", 0.0),
    tf("PlaySpeed", "double", "Number", "", [0.0]),
    ti("FreeRunning", "bool", "", "", 0.0),
    ti("Loop", "bool", "", "", 0.0),
    ti("InterlaceMode", "enum", "", "", 0.0),
    ti("ImageSequence", "bool", "", "", 0.0),
    ti("ImageSequenceOffset", "int", "Integer", "", 0.0),
    tf("FrameRate", "double", "Number", "", [0.0]),
    ti("LastFrame", "int", "Integer", "", 0.0)]

  ## String valued template rows need string payloads; handled separately.
  TmplName = ["", "", "FbxMesh", "FbxNode", "", "", "FbxSurfacePhong",
              "FbxFileTexture", "FbxVideo"]

  TmplIndex = toHashSet([2, 3, 6, 7, 8])

  TmplProps = [TmplGeometry, TmplModel, TmplGeometry, TmplModel, TmplGeometry,
               TmplGeometry, TmplMaterial, TmplTexture, TmplVideo]

# ---------------------------------------------------------------------------

type Exporter = object
  ids: Ids
  modelIds: seq[int64]        # per bone / object
  attrIds: seq[int64]         # per bone
  geomIds: seq[int64]         # per mesh
  shapeGeomIds: seq[seq[int64]]
  shapeDefIds: seq[seq[int64]]
  shapePoseIds: seq[seq[int64]]
  skinIds: seq[int64]
  poseIds: seq[int64]
  matIds: seq[int64]
  ## texture ids keyed by "<material index>|<fbx slot name>"
  texIds: Table[string, int64]
  ## video ids keyed by image name (shared between textures)
  videoIds: Table[string, int64]
  armatureId: int64
  armAttrId: int64
  blendShapeIds: seq[int64]
  objIds: seq[int64]
  connections: seq[tuple[a, b: string, c: int64, d: int64, p: string]]

proc exportScene*(s: Scene, outPath: string): string =
  var ids = newIds()
  var x: Exporter
  x.ids = ids
  let nBones = s.bones.len
  let nMeshes = s.meshes.len

  # --- ids ---
  x.armatureId = x.ids.getId("Model|Armature")
  x.armAttrId = x.ids.getId("NodeAttribute|Armature")
  x.modelIds = newSeq[int64](nBones + nMeshes + 1)
  x.attrIds = newSeq[int64](nBones)
  for i in 0..<nBones:
    x.modelIds[i] = x.ids.getId("Model|" & s.bones[i].name)
    x.attrIds[i] = x.ids.getId("NodeAttribute|" & s.bones[i].name)
  for i in 0..<nMeshes:
    x.modelIds[nBones + i] = x.ids.getId("Model|" & s.meshes[i].name)
  x.geomIds = newSeq[int64](nMeshes)
  for i in 0..<nMeshes:
    x.geomIds[i] = x.ids.getId("Geometry|" & s.meshes[i].name)
  x.shapeGeomIds = newSeq[seq[int64]](nMeshes)
  x.shapeDefIds = newSeq[seq[int64]](nMeshes)
  x.shapePoseIds = newSeq[seq[int64]](nMeshes)
  for i in 0..<nMeshes:
    let n = s.meshes[i].shapes.len
    x.shapeGeomIds[i] = newSeq[int64](n)
    x.shapeDefIds[i] = newSeq[int64](n)
    x.shapePoseIds[i] = newSeq[int64](n)
    for k in 0..<n:
      let nm = s.meshes[i].shapes[k].name
      x.shapeGeomIds[i][k] = x.ids.getId("Shape|" & nm)
      x.shapeDefIds[i][k] = x.ids.getId("Deformer|Shape|" & nm)
      x.shapePoseIds[i][k] = x.ids.getId("BindPose|" & nm)
  x.skinIds = newSeq[int64](nMeshes)
  x.poseIds = newSeq[int64](nMeshes)
  x.blendShapeIds = newSeq[int64](nMeshes)
  for i in 0..<nMeshes:
    x.skinIds[i] = x.ids.getId("DeformerSkin|" & s.meshes[i].name)
    x.poseIds[i] = x.ids.getId("BindPose|" & s.meshes[i].name)
    x.blendShapeIds[i] = x.ids.getId("BlendShape|" & s.meshes[i].name)
  x.matIds = newSeq[int64](s.materials.len)
  for i in 0..<s.materials.len:
    x.matIds[i] = x.ids.getId("Material|" & s.materials[i].name)
  for mi, mt in s.materials:
    for (fbxSlot, texName, nm) in [
        ("DiffuseColor", "base_color_texture", mt.baseTex),
        ("EmissiveColor", "emission_color_texture", mt.emissionTex),
        ("NormalMap", "normalmap_texture", mt.normalTex),
        ("TransparencyFactor", "alpha_texture", mt.alphaTex)]:
      if nm.len == 0: continue
      let key = $mi & "|" & fbxSlot
      x.texIds[key] = x.ids.getId("Texture|" & $mi & "|" & fbxSlot & "|" & nm)
      if not x.videoIds.hasKey(nm):
        x.videoIds[nm] = x.ids.getId("Video|" & nm)

  # --- header ---
  let root = newNode("")
  let hdr = elem(root, "FBXHeaderExtension")
  propI32(hdr, "FBXHeaderVersion", 1003)
  propI32(hdr, "FBXVersion", int(FbxVersion))
  propI32(hdr, "EncryptionType", 0)
  let ts = elem(hdr, "CreationTimeStamp")
  propI32(ts, "Version", 1000)
  let now = tms.local(tms.getTime())
  propI32(ts, "Year", now.year)
  propI32(ts, "Month", int(now.month) + 1)
  propI32(ts, "Day", int(now.monthday))
  propI32(ts, "Hour", now.hour)
  propI32(ts, "Minute", now.minute)
  propI32(ts, "Second", now.second)
  propI32(ts, "Millisecond", (now.nanosecond div 1000000) div 1000)
  propStr(hdr, "Creator", "CatelliteV2F (Nim) - 1.0.0")
  let sceneInfo = elem(hdr, "SceneInfo")
  sceneInfo.addString("GlobalInfo\x00\x01SceneInfo")
  sceneInfo.addString("UserData")
  propStr(sceneInfo, "Type", "UserData")
  propI32(sceneInfo, "Version", 100)
  let meta = elem(sceneInfo, "MetaData")
  propI32(meta, "Version", 100)
  for f in ["Title", "Subject", "Author", "Keywords", "Revision", "Comment"]:
    propStr(meta, f, "")
  let sip = elem(sceneInfo, "Properties70")
  const Stamp = "01/01/1970 00:00:00.000"
  propP(sip, "DocumentUrl", "KString", "Url", "", @["/foobar.fbx"])
  propP(sip, "SrcDocumentUrl", "KString", "Url", "", @["/foobar.fbx"])
  for grp in ["Original", "LastSaved"]:
    propP(sip, grp, "Compound", "", "", @[])
    propP(sip, grp & "|ApplicationVendor", "KString", "", "", @["Blender Foundation"])
    propP(sip, grp & "|ApplicationName", "KString", "", "", @["Blender (stable FBX IO)"])
    propP(sip, grp & "|ApplicationVersion", "KString", "", "", @["5.0.1"])
    propP(sip, grp & "|DateTime_GMT", "DateTime", "", "", @[Stamp])
    if grp == "Original":
      propP(sip, grp & "|FileName", "KString", "", "", @["/foobar.fbx"])
  propP(sip, "Original|ApplicationNativeFile", "KString", "", "", @[""])

  let fileId = elem(root, "FileId")
  fileId.addRaw(@[0x28'u8, 0xb3, 0x2a, 0xeb, 0xb6, 0x24, 0xcc, 0xc2, 0xbf, 0xc8,
                 0xb0, 0x2a, 0xa9, 0x2b, 0xfc, 0xf1])
  let ct = elem(root, "CreationTime")
  ct.addString("1970-01-01 10:00:00:000")
  let cr = elem(root, "Creator")
  cr.addString("CatelliteV2F (Nim) - 1.0.0")

  # --- global settings ---
  let gs = elem(root, "GlobalSettings")
  propI32(gs, "Version", 1000)
  let gsp = elem(gs, "Properties70")
  propPI(gsp, "UpAxis", "int", "Integer", "", 1)
  propPI(gsp, "UpAxisSign", "int", "Integer", "", 1)
  propPI(gsp, "FrontAxis", "int", "Integer", "", 2)
  propPI(gsp, "FrontAxisSign", "int", "Integer", "", 1)
  propPI(gsp, "CoordAxis", "int", "Integer", "", 0)
  propPI(gsp, "CoordAxisSign", "int", "Integer", "", 1)
  propPI(gsp, "OriginalUpAxis", "int", "Integer", "", -1)
  propPI(gsp, "OriginalUpAxisSign", "int", "Integer", "", 1)
  propPD(gsp, "UnitScaleFactor", "double", "Number", "", @[1.0])
  propPD(gsp, "OriginalUnitScaleFactor", "double", "Number", "", @[1.0])
  propPD(gsp, "AmbientColor", "ColorRGB", "Color", "", @[0.0, 0.0, 0.0])
  propP(gsp, "DefaultCamera", "KString", "", "", @["Producer Perspective"])
  propPI(gsp, "TimeMode", "enum", "", "", 11)
  propPI64(gsp, "TimeSpanStart", "KTime", "Time", "", 0)
  propPI64(gsp, "TimeSpanStop", "KTime", "Time", "", 46186158000)
  propPD(gsp, "CustomFrameRate", "double", "Number", "", @[24.0])

  # --- documents / references ---
  let docs = elem(root, "Documents")
  propI32(docs, "Count", 1)
  let doc = elem(docs, "Document")
  doc.addInt32(382214236)
  doc.addString("Scene")
  doc.addString("Scene")
  let dp = elem(doc, "Properties70")
  let dp1 = elem(dp, "P")
  dp1.addString("SourceObject"); dp1.addString("object"); dp1.addString(""); dp1.addString("")
  propP(dp, "ActiveAnimStackName", "KString", "", "", @[""])
  propI32(doc, "RootNode", 0)

  let refs = elem(root, "References")

  # --- definitions ---
  var nShapes = 0
  var nShapeMeshes = 0
  for m in s.meshes:
    if m.shapes.len > 0:
      inc nShapeMeshes
      nShapes += m.shapes.len
  var counts: seq[(string, int)] = @[
    ("GlobalSettings", 1), ("NodeAttribute", nBones + 1),
    ("Geometry", nMeshes + nShapes), ("Model", nBones + nMeshes + 1),
    ("Pose", 3),
    ("Deformer", 1 + nMeshes * nBones + nShapeMeshes + nShapes),
    ("Material", s.materials.len), ("Texture", 0), ("Video", 0)]
  var nTex = 0
  var nVid = 0
  for key in x.texIds.keys:
    if key[0].isDigit: inc nTex
  for key in x.videoIds.keys: inc nVid
  counts[7] = ("Texture", nTex)
  counts[8] = ("Video", nVid)
  var totalTemplates = 0
  for c in counts: totalTemplates += c[1]
  let defs = elem(root, "Definitions")
  propI32(defs, "Version", TemplatesVersion)
  propI32(defs, "Count", totalTemplates)
  for idx, c in counts:
    let ot = elem(defs, "ObjectType")
    ot.addString(c[0])
    propI32(ot, "Count", c[1])
    if idx in TmplIndex:
      let pt = elem(ot, "PropertyTemplate")
      pt.addString(TmplName[idx])
      let ps = elem(pt, "Properties70")
      for row in TmplProps[idx]:
        let p = elem(ps, "P")
        p.addString(row.name)
        p.addString(row.typ)
        p.addString(row.sub)
        p.addString(row.flags)
        case row.kind
        of tvFloat:
          for v in row.vals: p.addFloat64(v)
        of tvInt:
          for v in row.vals: p.addInt32(int32(v))
        of tvLong:
          for v in row.vals: p.addInt64(int64(v))
        of tvString:
          p.addString(row.text)
        of tvNone:
          discard

  # --- objects ---
  let objects = elem(root, "Objects")
  # armature node attribute
  let armAttr = elem(objects, "NodeAttribute")
  armAttr.addInt64(x.armAttrId)
  armAttr.addString(fbName("Armature", "NodeAttribute"))
  armAttr.addString("Null")
  propStr(armAttr, "TypeFlags", "Null")
  let aap = elem(armAttr, "Properties70")
  propPD(aap, "Color", "ColorRGB", "Color", "A", @[0.8, 0.8, 0.8])
  propPD(aap, "Size", "double", "Number", "", @[100.0])
  propPI(aap, "Look", "enum", "", "", 1)

  # geometries
  for i in 0..<nMeshes:
    let m = s.meshes[i]
    let g = elem(objects, "Geometry")
    g.addInt64(x.geomIds[i])
    g.addString(fbName(m.name, "Geometry"))
    g.addString("Mesh")
    let gp = elem(g, "Properties70")
    for sk in m.shapes:
      if sk.positions.len == 0: continue
      propPD(gp, sk.name, "Number", "", "A", @[0.0])
    propI32(g, "GeometryVersion", GeometryVersion)
    let verts = elem(g, "Vertices"); verts.addFloat64Array(m.verts)
    let pv = elem(g, "PolygonVertexIndex"); pv.addInt32Array(m.loops)
    if m.edges.len > 0:
      let e = elem(g, "Edges"); e.addInt32Array(m.edges)
    # normals
    let ln = elem(g, "LayerElementNormal")
    ln.addInt32(0)
    propI32(ln, "Version", 101)
    propStr(ln, "Name", "")
    propStr(ln, "MappingInformationType", "ByPolygonVertex")
    propStr(ln, "ReferenceInformationType", "IndexToDirect")
    propD(ln, "Normals", m.loopNormals)
    propI32Arr(ln, "NormalsIndex", m.loopNormalIdx)
    # uv
    let lu = elem(g, "LayerElementUV")
    lu.addInt32(0)
    propI32(lu, "Version", 101)
    propStr(lu, "Name", "UVMap")
    propStr(lu, "MappingInformationType", "ByPolygonVertex")
    propStr(lu, "ReferenceInformationType", "IndexToDirect")
    propD(lu, "UV", m.loopUv)
    propI32Arr(lu, "UVIndex", m.loopUvIdx)
    # materials
    let lm = elem(g, "LayerElementMaterial")
    lm.addInt32(0)
    propI32(lm, "Version", 101)
    propStr(lm, "Name", "")
    propStr(lm, "MappingInformationType", "ByPolygon")
    propStr(lm, "ReferenceInformationType", "IndexToDirect")
    propI32Arr(lm, "Materials", m.polyMat)
    let lay = elem(g, "Layer")
    lay.addInt32(0)
    propI32(lay, "Version", 100)
    for (t, idx) in [("LayerElementNormal", 0), ("LayerElementUV", 0),
                     ("LayerElementMaterial", 0)]:
      let le = elem(lay, "LayerElement")
      propStr(le, "Type", t)
      propI32(le, "TypedIndex", idx)

  # models: armature object, meshes, bones
  # The Blender -> FBX axis conversion.  Blender is Z up with the character
  # facing -Y; FBX is Y up, so Rx(-90) maps Blender +Z onto FBX +Y and Blender
  # -Y onto FBX +Z.  This is deliberately left exactly as the reference export
  # has it: Unity's model importer (with "Bake Axis Conversion" enabled, which
  # is what VRChat setups use) turns FBX +Z into Unity -Z, which is the forward
  # direction VRC wants.  Turning the model around here would undo that.
  let axisConv = rotX(-90.0)
  # `matToEulerXYZ` reads its argument as row major while `Mat4` is column
  # major, so a matrix built directly here has to be transposed first - the
  # bone nodes below do the same for `localRest`.
  let axisConvEuler = axisConv.transposed.matToEulerXYZ()
  let armModel = elem(objects, "Model")
  armModel.addInt64(x.armatureId)
  armModel.addString(fbName("Armature", "Model"))
  armModel.addString("Null")
  propI32(armModel, "Version", ModelVersion)
  var ap = elem(armModel, "Properties70")
  propPD(ap, "Lcl Rotation", "Lcl Rotation", "", "A",
           @[axisConvEuler[0], axisConvEuler[1], axisConvEuler[2]])
  propPD(ap, "Lcl Scaling", "Lcl Scaling", "", "A", @[100.0, 100.0, 100.0])
  propPI(ap, "DefaultAttributeIndex", "int", "Integer", "", 0)
  propPI(ap, "InheritType", "enum", "", "", 1)
  propI32(armModel, "MultiLayer", 0)
  propI32(armModel, "MultiTake", 0)
  elem(armModel, "Shading").addBool(true)
  propStr(armModel, "Culling", "CullingOff")

  for i in 0..<nMeshes:
    let m = elem(objects, "Model")
    m.addInt64(x.modelIds[nBones + i])
    m.addString(fbName(s.meshes[i].objName, "Model"))
    m.addString("Mesh")
    propI32(m, "Version", ModelVersion)
    let p = elem(m, "Properties70")
    propPD(p, "Lcl Rotation", "Lcl Rotation", "", "A",
           @[axisConvEuler[0], axisConvEuler[1], axisConvEuler[2]])
    propPD(p, "Lcl Scaling", "Lcl Scaling", "", "A", @[100.0, 100.0, 100.0])
    propPI(p, "DefaultAttributeIndex", "int", "Integer", "", 0)
    propPI(p, "InheritType", "enum", "", "", 1)
    propI32(m, "MultiLayer", 0)
    propI32(m, "MultiTake", 0)
    elem(m, "Shading").addBool(true)
    propStr(m, "Culling", "CullingOff")

  for i in 0..<nBones:
    let b = s.bones[i]
    let m = elem(objects, "Model")
    m.addInt64(x.modelIds[i])
    m.addString(fbName(b.name, "Model"))
    m.addString("LimbNode")
    propI32(m, "Version", ModelVersion)
    let d = b.localRest.decompose
    # Take the rotation straight off the matrix: going through
    # `decompose`/`quatToMat` re-derives a quaternion whose column/row
    # convention is the transpose of `localRest`, which flips the sign of the X
    # and Z Euler angles - and Unity builds the skeleton from these node
    # properties, not from BindPose.
    var rotMat = IdMat4
    rotMat.setCol(0, b.localRest.col(0).norm)
    rotMat.setCol(1, b.localRest.col(1).norm)
    rotMat.setCol(2, b.localRest.col(2).norm)
    let rot = rotMat.transposed.matToEulerXYZ()
    let p = elem(m, "Properties70")
    if abs(d.loc[0]) > 0 or abs(d.loc[1]) > 0 or abs(d.loc[2]) > 0:
      propPD(p, "Lcl Translation", "Lcl Translation", "", "A", @[d.loc[0], d.loc[1], d.loc[2]])
    if abs(rot[0]) > 0 or abs(rot[1]) > 0 or abs(rot[2]) > 0:
      propPD(p, "Lcl Rotation", "Lcl Rotation", "", "A", @[rot[0], rot[1], rot[2]])
    if abs(d.scale[0] - 1) > 1e-9 or abs(d.scale[1] - 1) > 1e-9 or abs(d.scale[2] - 1) > 1e-9:
      propPD(p, "Lcl Scaling", "Lcl Scaling", "", "A", @[d.scale[0], d.scale[1], d.scale[2]])
    propPI(p, "DefaultAttributeIndex", "int", "Integer", "", 0)
    propPI(p, "InheritType", "enum", "", "", 1)
    propI32(m, "MultiLayer", 0)
    propI32(m, "MultiTake", 0)
    elem(m, "Shading").addBool(true)
    propStr(m, "Culling", "CullingOff")

  # bone node attributes
  for i in 0..<nBones:
    let a = elem(objects, "NodeAttribute")
    a.addInt64(x.attrIds[i])
    a.addString(fbName(s.bones[i].name, "NodeAttribute"))
    a.addString("LimbNode")
    propStr(a, "TypeFlags", "Skeleton")
    let p = elem(a, "Properties70")
    propPD(p, "Size", "double", "Number", "", @[s.bones[i].size])

  # deformers: bind pose + skin + clusters per mesh
  let armWorld = scaling([100.0, 100.0, 100.0]) * axisConv
  for i in 0..<nMeshes:
    # BindPose
    let pose = elem(objects, "Pose")
    pose.addInt64(x.poseIds[i])
    pose.addString(fbName(s.meshes[i].name, "Pose"))
    pose.addString("BindPose")
    propStr(pose, "Type", "BindPose")
    propI32(pose, "Version", PoseVersion)
    propI32(pose, "NbPoseNodes", 2 + nBones)
    var pn = elem(pose, "PoseNode")
    propI64(pn, "Node", x.modelIds[nBones + i])
    propD(pn, "Matrix", mat4Array(armWorld))
    pn = elem(pose, "PoseNode")
    propI64(pn, "Node", x.armatureId)
    propD(pn, "Matrix", mat4Array(armWorld))
    for b in 0..<nBones:
      pn = elem(pose, "PoseNode")
      propI64(pn, "Node", x.modelIds[b])
      propD(pn, "Matrix", mat4Array(armWorld * s.bones[b].worldRest))
    # Skin deformer
    let skin = elem(objects, "Deformer")
    skin.addInt64(x.skinIds[i])
    skin.addString(fbName("Armature", "Deformer"))
    skin.addString("Skin")
    propI32(skin, "Version", SkinVersion)
    propF64(skin, "Link_DeformAcuracy", 50.0)
    # clusters
    var boneWeights = initTable[int, Table[int, float64]]()
    for vi, lst in s.meshes[i].weights:
      for (bi, w) in lst:
        if not boneWeights.hasKey(bi): boneWeights[bi] = initTable[int, float64]()
        boneWeights[bi][vi] = w
    for b in 0..<nBones:
      let cl = elem(objects, "Deformer")
      cl.addInt64(x.ids.getId("SubDeformerCluster|" & s.meshes[i].name & "|" & s.bones[b].name))
      cl.addString(fbName(s.bones[b].name, "SubDeformer"))
      cl.addString("Cluster")
      propI32(cl, "Version", ClusterVersion)
      let ud = elem(cl, "UserData")
      ud.addString("")
      ud.addString("")
      if boneWeights.hasKey(b):
        var idxs: seq[int32] = @[]
        var ws: seq[float64] = @[]
        for vi, w in pairs(boneWeights[b]):
          idxs.add(int32(vi))
          ws.add(w)
        propI32Arr(cl, "Indexes", idxs)
        propD(cl, "Weights", ws)
      let boneWorld = armWorld * s.bones[b].worldRest
      propD(cl, "Transform", mat4Array(boneWorld.invertSafe * armWorld))
      propD(cl, "TransformLink", mat4Array(boneWorld))
      propD(cl, "TransformAssociateModel", mat4Array(armWorld))

  # shape key deformers
  for i in 0..<nMeshes:
    if s.meshes[i].shapes.len == 0: continue
    for k, sk in s.meshes[i].shapes:
      let g = elem(objects, "Geometry")
      g.addInt64(x.shapeGeomIds[i][k])
      g.addString(fbName(sk.name, "Geometry"))
      g.addString("Shape")
      discard elem(g, "Properties70")
      propI32(g, "Version", 100)
      propI32Arr(g, "Indexes", sk.indices)
      propD(g, "Vertices", sk.positions)
      var nz = newSeq[float64](sk.indices.len * 3)
      propD(g, "Normals", nz)
      # BlendShapeChannel, one per shape key.  Blender registers these under
      # the SubDeformer class, not Deformer.
      let d = elem(objects, "Deformer")
      d.addInt64(x.shapeDefIds[i][k])
      d.addString(fbName(sk.name, "SubDeformer"))
      d.addString("BlendShapeChannel")
      propI32(d, "Version", 100)
      propF64(d, "DeformPercent", 0.0)
      var fw = newSeq[float64](sk.indices.len)
      for j in 0..<fw.len: fw[j] = 100.0
      propD(d, "FullWeights", fw)
    # the BlendShape deformer grouping all channels of this mesh
    let sd = elem(objects, "Deformer")
    sd.addInt64(x.blendShapeIds[i])
    sd.addString(fbName(s.meshes[i].name, "Deformer"))
    sd.addString("BlendShape")
    propI32(sd, "Version", 100)

  # shape bind pose (one per mesh with shapes, only the mesh node)
  for i in 0..<nMeshes:
    if s.meshes[i].shapes.len == 0: continue
    let pose = elem(objects, "Pose")
    pose.addInt64(x.ids.getId("ShapeBindPose|" & s.meshes[i].name))
    pose.addString(fbName(s.meshes[i].name, "Pose"))
    pose.addString("BindPose")
    propStr(pose, "Type", "BindPose")
    propI32(pose, "Version", PoseVersion)
    propI32(pose, "NbPoseNodes", 1)
    let pn = elem(pose, "PoseNode")
    propI64(pn, "Node", x.modelIds[nBones + i])
    propD(pn, "Matrix", mat4Array(armWorld))

  # materials
  for i, mt in s.materials:
    let m = elem(objects, "Material")
    m.addInt64(x.matIds[i])
    m.addString(fbName(mt.name, "Material"))
    m.addString("")
    propI32(m, "Version", MaterialVersion)
    propStr(m, "ShadingModel", "Phong")
    propI32(m, "MultiLayer", 0)
    let p = elem(m, "Properties70")
    # Only properties that differ from the FBX Phong template defaults are
    # written; `Color` here is the 3 component variant Blender emits.
    propPD(p, "DiffuseColor", "Color", "", "A", @[mt.diffuse[0], mt.diffuse[1], mt.diffuse[2]])
    if mt.emission[0] != 0.0 or mt.emission[1] != 0.0 or mt.emission[2] != 0.0:
      propPD(p, "EmissiveColor", "Color", "", "A", @[mt.emission[0], mt.emission[1], mt.emission[2]])
    propPD(p, "AmbientColor", "Color", "", "A", @[mt.ambient, mt.ambient, mt.ambient])
    propPD(p, "AmbientFactor", "Number", "", "A", @[0.0])
    propPD(p, "SpecularColor", "Color", "", "A", @[1.0, 1.0, 1.0])
    propPD(p, "SpecularFactor", "Number", "", "A", @[0.0])
    propPD(p, "Shininess", "Number", "", "A", @[0.0])
    propPD(p, "ShininessExponent", "Number", "", "A", @[0.0])
    propPD(p, "ReflectionColor", "Color", "", "A", @[1.0, 1.0, 1.0])

  # textures: Blender emits one Texture object per material slot, each
  # pointing at a (shared) Video object.
  for mi, mt in s.materials:
    for (fbxSlot, texName, nm) in [
        ("DiffuseColor", "base_color_texture", mt.baseTex),
        ("EmissiveColor", "emission_color_texture", mt.emissionTex),
        ("NormalMap", "normalmap_texture", mt.normalTex),
        ("TransparencyFactor", "alpha_texture", mt.alphaTex)]:
      if nm.len == 0: continue
      let key = $mi & "|" & fbxSlot
      let t = elem(objects, "Texture")
      t.addInt64(x.texIds[key])
      t.addString(fbName(texName, "Texture"))
      t.addString("")
      propStr(t, "Type", "TextureVideoClip")
      propI32(t, "Version", TextureVersion)
      propStr(t, "TextureName", fbName(texName, "Texture"))
      propStr(t, "Media", fbName(nm, "Video"))
      let fileName = s.fbmBase & nm & ".png"
      propStr(t, "FileName", fileName)
      propStr(t, "RelativeFilename", fbmName(s.fbmBase) & "\\" & nm & ".png")
      let p = elem(t, "Properties70")
      propPB(p, "PremultiplyAlpha", "bool", "", "", false)
      propPB(p, "UseMaterial", "bool", "", "", true)

  # videos (one per distinct image, in first-use order)
  var vidSeen = initOrderedSet[string]()
  for mt in s.materials:
    for nm in [mt.baseTex, mt.emissionTex, mt.normalTex, mt.alphaTex]:
      if nm.len == 0 or nm in vidSeen: continue
      vidSeen.incl nm
      var data: seq[byte] = @[]
      for im in s.images:
        if im.name == nm: data = im.data
      let v = elem(objects, "Video")
      v.addInt64(x.videoIds[nm])
      v.addString(fbName(nm, "Video"))
      v.addString("Clip")
      propStr(v, "Type", "Clip")
      let p = elem(v, "Properties70")
      # `Filename` must be present: importers decide between "embedded" and
      # "linked" from it, and Unity additionally resolves textures from disk
      # rather than from `Content`, so the `.fbm` folder written next to the
      # FBX is what actually feeds the materials.  The bytes go in `Content` as
      # well, exactly like Blender's `embed_textures=True`.
      propP(p, "Path", "KString", "Url", "", @[s.fbmBase & nm & ".png"])
      propI32(v, "UseMipMap", 0)
      propStr(v, "Filename", s.fbmBase & nm & ".png")
      propStr(v, "RelativeFilename", fbmName(s.fbmBase) & "\\" & nm & ".png")
      let c = elem(v, "Content")
      c.addRaw(data)

  # --- connections ---
  let conns = elem(root, "Connections")
  proc conn(kind: string, src, dst: int64, prop = "") =
    let e = elem(conns, "C")
    e.addString(kind)
    e.addInt64(src)
    e.addInt64(dst)
    if prop.len > 0: e.addString(prop)
  conn("OO", x.armatureId, 0)
  for i in 0..<nBones:
    conn("OO", x.modelIds[i],
         (if s.bones[i].parent < 0: x.armatureId else: x.modelIds[s.bones[i].parent]))
  for i in 0..<nBones:
    conn("OO", x.attrIds[i], x.modelIds[i])
  conn("OO", x.armAttrId, x.armatureId)
  for i in 0..<nMeshes:
    conn("OO", x.modelIds[nBones + i], 0)
    conn("OO", x.geomIds[i], x.modelIds[nBones + i])
  for i in 0..<nMeshes:
    for b in 0..<nBones:
      let cluster = x.ids.getId("SubDeformerCluster|" & s.meshes[i].name & "|" & s.bones[b].name)
      conn("OO", cluster, x.skinIds[i])
      # Blender also links the bone node to its cluster
      conn("OO", x.modelIds[b], cluster)
    conn("OO", x.skinIds[i], x.geomIds[i])
    for mtIdx in s.meshes[i].matIndices:
      if mtIdx < s.materials.len and mtIdx < x.matIds.len:
        conn("OO", x.matIds[mtIdx], x.modelIds[nBones + i])
  for i in 0..<nMeshes:
    if s.meshes[i].shapes.len == 0: continue
    conn("OO", x.blendShapeIds[i], x.geomIds[i])
    for k, sk in s.meshes[i].shapes:
      conn("OO", x.shapeDefIds[i][k], x.blendShapeIds[i])
      conn("OO", x.shapeGeomIds[i][k], x.shapeDefIds[i][k])
  for mi, mt in s.materials:
    for (fbxSlot, nm) in [("DiffuseColor", mt.baseTex),
                          ("EmissiveColor", mt.emissionTex),
                          ("NormalMap", mt.normalTex),
                          ("TransparencyFactor", mt.alphaTex)]:
      if nm.len == 0: continue
      let key = $mi & "|" & fbxSlot
      conn("OP", x.texIds[key], x.matIds[mi], fbxSlot)
      conn("OO", x.videoIds[nm], x.texIds[key])

  # --- takes ---
  let takes = elem(root, "Takes")
  propStr(takes, "Current", "")

  let data = root.encode(FbxVersion)
  writeFile(outPath, data)
  result = outPath
