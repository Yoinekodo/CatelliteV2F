## Minimal JSON reader (DOM) plus GLB / VRM container parsing.
import std/[strutils, tables]
import ./m3

type
  JKind* = enum jNull, jBool, jNum, jStr, jArr, jObj
  JNode* = ref object
    kind*: JKind
    bval*: bool
    nval*: float64
    sval*: string
    items*: seq[JNode]
    fields*: OrderedTable[string, JNode]

proc newNode(k: JKind): JNode =
  new(result)
  result.fields = initOrderedTable[string, JNode]()
  result.items = @[]
  result.kind = k

proc parseJson*(s: string): JNode =
  var p = 0
  let n = s.len

  proc skipWs() =
    while p < n and s[p] in {' ', '\t', '\n', '\r'}: inc p

  proc parseStr(): string =
    inc p
    var buf = newStringOfCap(16)
    while p < n:
      let c = s[p]
      if c == '"':
        inc p
        break
      if c == '\\':
        inc p
        if p >= n: break
        case s[p]
        of '"': buf.add('"')
        of '\\': buf.add('\\')
        of '/': buf.add('/')
        of 'b': buf.add('\b')
        of 'f': buf.add('\f')
        of 'n': buf.add('\n')
        of 'r': buf.add('\r')
        of 't': buf.add('\t')
        of 'u':
          var code = 0
          for i in 1..4:
            inc p
            code = code * 16 + (if s[p] in {'0'..'9'}: ord(s[p]) - ord('0')
                                  else: (ord(s[p]) or 32) - ord('a') + 10)
          if code < 0x80:
            buf.add(char(code))
          elif code < 0x800:
            buf.add(char(0xC0 or (code shr 6)))
            buf.add(char(0x80 or (code and 0x3F)))
          else:
            buf.add(char(0xE0 or (code shr 12)))
            buf.add(char(0x80 or ((code shr 6) and 0x3F)))
            buf.add(char(0x80 or (code and 0x3F)))
        else: buf.add(s[p])
        inc p
      else:
        buf.add(c)
        inc p
    result = buf

  proc parseVal(): JNode =
    skipWs()
    if p >= n:
      return newNode(jNull)
    case s[p]
    of '{':
      inc p
      result = newNode(jObj)
      skipWs()
      if p < n and s[p] == '}':
        inc p
        return
      while p < n:
        skipWs()
        let key = parseStr()
        skipWs()
        if p < n and s[p] == ':': inc p
        result.fields[key] = parseVal()
        skipWs()
        if p < n and s[p] == ',':
          inc p
        elif p < n and s[p] == '}':
          inc p
          break
        else:
          break
    of '[':
      inc p
      result = newNode(jArr)
      skipWs()
      if p < n and s[p] == ']':
        inc p
        return
      while p < n:
        result.items.add(parseVal())
        skipWs()
        if p < n and s[p] == ',':
          inc p
        elif p < n and s[p] == ']':
          inc p
          break
        else:
          break
    of '"':
      result = newNode(jStr)
      result.sval = parseStr()
    of 't':
      inc p
      result = newNode(jBool)
      result.bval = true
      p = min(p + 3, n)
    of 'f':
      inc p
      result = newNode(jBool)
      result.bval = false
      p = min(p + 4, n)
    of 'n':
      inc p
      result = newNode(jNull)
      p = min(p + 3, n)
    else:
      result = newNode(jNum)
      let start = p
      while p < n and (s[p] in {'+', '-', '.', 'e', 'E'} or s[p] in {'0'..'9'}): inc p
      result.nval = parseFloat(s[start ..< p])

  result = parseVal()

proc get*(o: JNode, key: string): JNode =
  if o != nil and o.kind == jObj and o.fields.hasKey(key): o.fields[key] else: nil

proc getStr*(o: JNode, key: string, def = ""): string =
  let v = o.get(key)
  if v != nil and v.kind == jStr: v.sval else: def

proc getInt*(o: JNode, key: string, def = 0): int =
  let v = o.get(key)
  if v != nil and v.kind == jNum: int(v.nval) else: def

proc getNum*(o: JNode, key: string, def = 0.0): float64 =
  let v = o.get(key)
  if v != nil and v.kind == jNum: v.nval else: def

proc getArr*(o: JNode, key: string): seq[JNode] =
  let v = o.get(key)
  if v != nil and v.kind == jArr: v.items else: @[]

proc has*(o: JNode, key: string): bool = o.get(key) != nil

# ---- glTF / VRM -----------------------------------------------------------

type
  GltfNode* = object
    name*: string
    children*: seq[int]
    parent*: int
    mesh*: int
    skin*: int
    translation*: Vec3
    rotation*: Quat
    scale*: Vec3
    matrix*: Mat4
    hasMatrix*: bool

  GltfPrimitive* = object
    attributes*: Table[string, int]
    indices*: int
    material*: int
    mode*: int
    targetCount*: int
    targetPos*: seq[int]

  GltfMesh* = object
    name*: string
    primitives*: seq[GltfPrimitive]
    targetNames*: seq[string]

  GltfSkin* = object
    joints*: seq[int]
    skeleton*: int
    ibmAccessor*: int

  GltfMaterial* = object
    name*: string
    baseColorFactor*: array[4, float64]
    mtoon*: JNode
    mtoonTexNames*: seq[string]
    mtoonTexIndices*: array[4, int]
    alphaMode*: string
    ## VRM 0.x: MToon parameters live in `extensions.VRM.materialProperties`
    emissionColor*: array[3, float64]
    blendMode*: int

  GltfImage* = object
    name*: string
    mimeType*: string
    uri*: string
    bufferView*: int
    data*: seq[byte]

  GltfTexture* = object
    source*: int

  VrmFile* = ref object
    json*: JNode
    binary*: seq[byte]
    nodes*: seq[GltfNode]
    meshes*: seq[GltfMesh]
    skins*: seq[GltfSkin]
    materials*: seq[GltfMaterial]
    images*: seq[GltfImage]
    textures*: seq[GltfTexture]
    bufferViews*: seq[tuple[offset, length: int]]
    accessors*: seq[Table[string, JNode]]
    humanBones*: Table[string, int]
    isVrm1*: bool

proc readU32(d: seq[byte], off: int): uint32 =
  cast[uint32](d[off]) or (cast[uint32](d[off + 1]) shl 8) or
  (cast[uint32](d[off + 2]) shl 16) or (cast[uint32](d[off + 3]) shl 24)

proc readU16(d: seq[byte], off: int): uint16 =
  cast[uint16](cast[uint16](d[off]) or (cast[uint16](d[off + 1]) shl 8))

proc parseGltf*(data: seq[byte]): VrmFile =
  if data.len < 20: raise newException(ValueError, "not a glb file")
  let magic = readU32(data, 0)
  if magic != 0x46546C67'u32: raise newException(ValueError, "bad glb magic")
  new(result)
  var off = 12
  var jsonChunk = ""
  while off + 8 <= data.len:
    let clen = int(readU32(data, off))
    let ctype = readU32(data, off + 4)
    if ctype == 0x4E4F534A'u32:
      jsonChunk = newString(clen)
      for i in 0..<clen: jsonChunk[i] = char(data[off + 8 + i])
    elif ctype == 0x004E4942'u32:
      result.binary = newSeq[byte](clen)
      for i in 0..<clen: result.binary[i] = data[off + 8 + i]
    off += 8 + clen
    if clen == 0: break
  result.json = parseJson(jsonChunk)

  let j = result.json
  for bv in j.getArr("bufferViews"):
    result.bufferViews.add((bv.getInt("byteOffset"), bv.getInt("byteLength")))
  for a in j.getArr("accessors"):
    var t: Table[string, JNode] = initTable[string, JNode]()
    for k, v in a.fields: t[k] = v
    result.accessors.add(t)

  for nd in j.getArr("nodes"):
    var n: GltfNode
    n.name = nd.getStr("name")
    n.parent = -1
    n.mesh = -1
    n.skin = -1
    n.translation = [0.0, 0.0, 0.0]
    n.scale = [1.0, 1.0, 1.0]
    n.rotation = [0.0, 0.0, 0.0, 1.0]
    for c in nd.getArr("children"): n.children.add(int(c.nval))
    if nd.has("mesh"): n.mesh = nd.getInt("mesh")
    if nd.has("skin"): n.skin = nd.getInt("skin")
    let tArr = nd.getArr("translation")
    if tArr.len == 3:
      n.translation = [tArr[0].nval, tArr[1].nval, tArr[2].nval]
    let rArr = nd.getArr("rotation")
    if rArr.len == 4:
      n.rotation = [rArr[0].nval, rArr[1].nval, rArr[2].nval, rArr[3].nval]
    let sArr = nd.getArr("scale")
    if sArr.len == 3:
      n.scale = [sArr[0].nval, sArr[1].nval, sArr[2].nval]
    let m = nd.getArr("matrix")
    if m.len == 16:
      n.hasMatrix = true
      for i in 0..3:
        for k in 0..3:
          n.matrix[i][k] = m[i * 4 + k].nval
    result.nodes.add(n)
  for i, n in result.nodes:
    for c in n.children:
      if c >= 0 and c < result.nodes.len:
        result.nodes[c].parent = i

  for md in j.getArr("meshes"):
    var m: GltfMesh
    m.name = md.getStr("name")
    let extras = md.get("extras")
    if extras != nil:
      for tn in extras.getArr("targetNames"):
        # VRM 0.x stores plain strings, some exporters use { "n": ... }
        m.targetNames.add(if tn.kind == jStr: tn.sval else: tn.getStr("n"))
    for pd in md.getArr("primitives"):
      var p: GltfPrimitive
      let at = pd.get("attributes")
      if at != nil:
        for k, v in at.fields:
          p.attributes[k] = int(v.nval)
      if pd.has("indices"): p.indices = pd.getInt("indices")
      if pd.has("material"): p.material = pd.getInt("material")
      p.mode = pd.getInt("mode", 4)
      for tg in pd.getArr("targets"):
        p.targetCount += 1
        p.targetPos.add(tg.getInt("POSITION", -1))
      m.primitives.add(p)
    result.meshes.add(m)

  for sd in j.getArr("skins"):
    var s: GltfSkin
    for jd in sd.getArr("joints"): s.joints.add(int(jd.nval))
    if sd.has("skeleton"): s.skeleton = sd.getInt("skeleton")
    s.ibmAccessor = sd.getInt("inverseBindMatrices", -1)
    result.skins.add(s)

  for md in j.getArr("materials"):
    var mt: GltfMaterial
    mt.name = md.getStr("name")
    mt.baseColorFactor = [1.0, 1.0, 1.0, 1.0]
    let bc = md.getArr("pbrMetallicRoughness")
    if bc.len > 0:
      let bf = bc[0].getArr("baseColorFactor")
      if bf.len == 4:
        mt.baseColorFactor = [bf[0].nval, bf[1].nval, bf[2].nval, bf[3].nval]
    let exts = md.get("extensions")
    let mto = if exts != nil: exts.get("VRM_materials_mtoon") else: nil
    if mto != nil:
      mt.mtoon = mto
      let slotKeys = ["baseColorTexture", "normalTexture",
                      "emissiveTexture", "alphaMode"]
      var names: seq[string] = @[]
      var idxs = [-1, -1, -1, -1]
      for si in 0..3:
        let t = mto.get(slotKeys[si])
        if t != nil and t.kind == jObj:
          names.add(t.getStr("name"))
          idxs[si] = t.getInt("index", -1)
        else:
          names.add("")
      mt.mtoonTexNames = names
      mt.mtoonTexIndices = idxs
    else:
      # VRM 0.x: plain glTF slots mapped onto the MToon shader.
      mt.mtoonTexIndices[0] = md.get("pbrMetallicRoughness").get("baseColorTexture")
                             .getInt("index", -1)
      mt.mtoonTexIndices[1] = md.get("normalTexture").getInt("index", -1)
      mt.mtoonTexIndices[2] = md.get("emissiveTexture").getInt("index", -1)
    mt.alphaMode = md.getStr("alphaMode", "OPAQUE")
    result.materials.add(mt)

  # VRM 0.x MToon material properties, matched by name.
  let vrmExt = j.get("extensions").get("VRM")
  if vrmExt != nil:
    var propsByName = initTable[string, JNode]()
    for mp in vrmExt.getArr("materialProperties"):
      let nm = mp.getStr("name")
      if nm.len > 0 and mp.getStr("shader") == "VRM/MToon":
        propsByName[nm] = mp
    for mt in result.materials.mitems:
      if not propsByName.hasKey(mt.name): continue
      let mp = propsByName[mt.name]
      let ecArr = mp.get("vectorProperties").get("_EmissionColor")
      if ecArr != nil and ecArr.kind == jArr and ecArr.items.len >= 3:
        for c in 0..<3:
          mt.emissionColor[c] = ecArr.items[c].nval
      mt.blendMode = int(mp.get("floatProperties").getNum("_BlendMode", 1.0))

  for im in j.getArr("images"):
    var im2: GltfImage
    im2.name = im.getStr("name")
    im2.mimeType = im.getStr("mimeType")
    im2.uri = im.getStr("uri")
    im2.bufferView = im.getInt("bufferView", -1)
    if im2.bufferView >= 0 and im2.bufferView < result.bufferViews.len:
      let bo = result.bufferViews[im2.bufferView][0]
      let bl = result.bufferViews[im2.bufferView][1]
      var d = newSeq[byte](bl)
      for i in 0..<bl:
        if bo + i < result.binary.len: d[i] = result.binary[bo + i]
      im2.data = d
    result.images.add(im2)

  for td in j.getArr("textures"):
    var t: GltfTexture
    t.source = td.getInt("source", -1)
    result.textures.add(t)

  let ext = j.get("extensions")
  if ext != nil:
    let vrm = ext.get("VRM")
    if vrm != nil:
      result.isVrm1 = vrm.has("humanoid")
      let hum = vrm.get("humanoid")
      if hum != nil:
        for hb in hum.getArr("humanBones"):
          result.humanBones[hb.getStr("bone")] = hb.getInt("node", -1)

# ---- accessor reading -----------------------------------------------------

const
  CompSizes = toTable({"5120": 1, "5121": 1, "5122": 2, "5123": 2, "5125": 4, "5126": 4})
  TypeCounts = toTable({"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4,
                "MAT2": 4, "MAT3": 9, "MAT4": 16})

proc compSize(ct: int): int =
  let k = $ct
  if CompSizes.hasKey(k): CompSizes[k] else: 4

proc accessorInfo*(g: VrmFile, idx: int): tuple[count, comps, compType,
    view, viewOff, accOff, stride: int] =
  if idx < 0 or idx >= g.accessors.len: return
  let a = g.accessors[idx]
  if a.hasKey("count"): result.count = int(a["count"].nval)
  if a.hasKey("componentType"): result.compType = int(a["componentType"].nval)
  if a.hasKey("bufferView"): result.view = int(a["bufferView"].nval)
  if a.hasKey("byteOffset"): result.accOff = int(a["byteOffset"].nval)
  if result.view >= 0 and result.view < g.bufferViews.len:
    result.viewOff = g.bufferViews[result.view][0]
  if a.hasKey("type"):
    let t = a["type"]
    if t.kind == jStr and TypeCounts.hasKey(t.sval):
      result.comps = TypeCounts[t.sval]

proc readComp(bin: seq[byte], off, ct: int): float64 =
  case ct
  of 5120: float64(cast[int8](bin[off]))
  of 5121: float64(bin[off])
  of 5122: float64(cast[int16](readU16(bin, off)))
  of 5123: float64(readU16(bin, off))
  of 5125: float64(cast[int32](readU32(bin, off)))
  else:
    float64(cast[float32](readU32(bin, off)))

proc readVec*(g: VrmFile, idx, comp: int): seq[float64] =
  let info = g.accessorInfo(idx)
  let esz = compSize(info.compType)
  let stride = if info.stride > 0: info.stride else: esz * comp
  result = newSeq[float64](info.count * comp)
  if info.view < 0: return
  for i in 0..<info.count:
    let base = info.viewOff + info.accOff + i * stride
    if base + esz * comp > g.binary.len: break
    for c in 0..<comp:
      result[i * comp + c] = readComp(g.binary, base + c * esz, info.compType)

proc readV3*(g: VrmFile, idx: int): seq[Vec3] =
  let info = g.accessorInfo(idx)
  let esz = compSize(info.compType)
  let st = if info.stride > 0: info.stride else: esz * info.comps
  result = newSeq[Vec3](info.count)
  if info.view < 0: return
  for i in 0..<info.count:
    let base = info.viewOff + info.accOff + i * st
    if base + esz * info.comps > g.binary.len: break
    result[i] = [readComp(g.binary, base, info.compType),
                 readComp(g.binary, base + esz, info.compType),
                 readComp(g.binary, base + 2 * esz, info.compType)]

proc readV2*(g: VrmFile, idx: int): seq[array[2, float64]] =
  let info = g.accessorInfo(idx)
  let esz = compSize(info.compType)
  let st = if info.stride > 0: info.stride else: esz * info.comps
  result = newSeq[array[2, float64]](info.count)
  if info.view < 0: return
  for i in 0..<info.count:
    let base = info.viewOff + info.accOff + i * st
    if base + esz * info.comps > g.binary.len: break
    result[i] = [readComp(g.binary, base, info.compType),
                 readComp(g.binary, base + esz, info.compType)]

proc readIndices*(g: VrmFile, idx: int): seq[int] =
  let info = g.accessorInfo(idx)
  let esz = compSize(info.compType)
  result = newSeq[int](info.count)
  if info.view < 0: return
  for i in 0..<info.count:
    let off = info.viewOff + info.accOff + i * esz
    if off + esz > g.binary.len: break
    result[i] = int(readComp(g.binary, off, info.compType))

proc readMat4*(g: VrmFile, idx: int): seq[Mat4] =
  let info = g.accessorInfo(idx)
  let esz = compSize(info.compType)
  result = newSeq[Mat4](info.count)
  if info.view < 0: return
  for i in 0..<info.count:
    let base = info.viewOff + info.accOff + i * 16 * esz
    if base + 16 * esz > g.binary.len: break
    for r in 0..3:
      for c in 0..3:
        result[i][r][c] = readComp(g.binary, base + (r * 4 + c) * esz, info.compType)
