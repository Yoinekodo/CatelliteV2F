## VRM -> FBX conversion pipeline.
##
## Reproduces the behaviour of the original Blender based tool:
##   * VRM import as done by the VRM Add-on for Blender (Y-up -> Z-up with the
##     model turned around, metre scale kept on the armature object, humanoid
##     bone renaming, dummy root bone removal, upper chest merge),
##   * Cats-Blender-Plugin viseme shapes and eye tracking bones,
##   * estimated humanoid T-pose applied to the rest pose (mesh included),
##   * the Spine/Chest/Neck bone fixup done by the original script.
import std/[tables, sets, strutils, math, os]
import ./core/m3
import ./core/glb

type
  Bone* = object
    name*: string
    srcName*: string
    parent*: int
    children*: seq[int]
    head*: Vec3
    tail*: Vec3
    worldRest*: Mat4
    localRest*: Mat4
    size*: float64
    humanName*: string
    rotQuat*: Quat
    scaleVec*: Vec3

  ShapeKey* = object
    name*: string
    positions*: seq[float64]
    indices*: seq[int32]

  Mesh* = object
    name*: string
    srcMesh*: int
    ## Blender object name (glTF node name); `name` is the mesh data name.
    objName*: string
    verts*: seq[float64]
    normals*: seq[float64]
    loopNormals*: seq[float64]
    loopNormalIdx*: seq[int32]
    loopUv*: seq[float64]
    loopUvIdx*: seq[int32]
    loops*: seq[int32]
    edges*: seq[int32]
    polyMat*: seq[int32]
    weights*: seq[seq[tuple[idx: int, w: float64]]]
    matIndices*: seq[int]
    shapes*: seq[ShapeKey]

  MatDef* = object
    name*: string
    diffuse*: array[3, float64]
    ambient*: float64
    emission*: array[3, float64]
    baseTex*: string
    normalTex*: string
    emissionTex*: string
    alphaTex*: string

  Texture* = object
    name*: string
    fileName*: string
    relFileName*: string
    data*: seq[byte]

  Scene* = ref object
    bones*: seq[Bone]
    meshes*: seq[Mesh]
    materials*: seq[MatDef]
    images*: seq[Texture]
    ## "<vrm dir>\<vrm name>.fbm\" - where Blender exported the texture folder.
    fbmBase*: string
    poseWorld*: seq[Mat4]
    ## glTF node index -> final bone index (bones that were merged away are
    ## redirected to the bone that absorbed them).
    nodeBoneMap*: Table[int, int]

proc fbmName*(base: string): string =
  ## "C:\models\luna.fbm\" -> "luna.fbm"
  result = base
  while result.len > 0 and (result[^1] == '\\' or result[^1] == '/'):
    result.setLen(result.len - 1)
  let cut = max(result.rfind('\\'), result.rfind('/'))
  if cut >= 0: result = result[cut + 1 .. ^1]

proc fbmDirFor*(fbxPath: string): string =
  ## Blender's FBX exporter copies the referenced images into a `<name>.fbm`
  ## folder next to the FBX it writes.  `FileName` / `RelativeFilename` point
  ## there and that is where Unity looks, so the folder name has to follow the
  ## *output* file, not the input VRM.
  result = fbxPath.extractFilename
  let dot = result.rfind('.')
  if dot > 0: result = result[0 ..< dot]
  result = result & ".fbm\\"
  let dir = fbxPath.parentDir
  if dir.len > 0: result = dir & "\\" & result

proc ensureOutputDir*(fbxPath: string) =
  ## Create the folder the FBX is about to be written into, so that pointing at
  ## a new location does not fail on a missing directory.
  let dir = fbxPath.parentDir
  if dir.len == 0 or dirExists(dir): return
  try:
    createDir(dir)
  except CatchableError:
    discard

proc writeTextureFolder*(s: Scene): string =
  ## Drop every embedded image into the `.fbm` folder.  FBX also carries the
  ## PNGs inside `Video/Content`, but Unity (like every other consumer) resolves
  ## textures from disk and ignores the embedded copies - without this folder
  ## every material imports untextured.
  result = s.fbmBase
  if s.images.len == 0: return
  try:
    createDir(result)
  except CatchableError:
    return
  for im in s.images:
    try:
      writeFile(result & im.name & ".png", im.data)
    except CatchableError:
      discard

const
  HumanNameMap = toTable({"hips": "Hips", "spine": "Spine", "chest": "Chest",
    "neck": "Neck", "head": "Head", "jaw": "Jaw",
    "leftShoulder": "Left shoulder", "rightShoulder": "Right shoulder",
    "leftUpperArm": "Left arm", "rightUpperArm": "Right arm",
    "leftLowerArm": "Left elbow", "rightLowerArm": "Right elbow",
    "leftHand": "Left wrist", "rightHand": "Right wrist",
    "leftUpperLeg": "Left leg", "rightUpperLeg": "Right leg",
    "leftLowerLeg": "Left knee", "rightLowerLeg": "Right knee",
    "leftFoot": "Left ankle", "rightFoot": "Right ankle",
    "leftToes": "Left toe", "rightToes": "Right toe",
    "leftBreast": "Breast_L", "rightBreast": "Breast_R",
    "leftThumbMetacarpal": "Thumb0_L", "leftThumbProximal": "Thumb0_L",
    "leftThumbIntermediate": "Thumb1_L", "leftThumbDistal": "Thumb2_L",
    "rightThumbMetacarpal": "Thumb0_R", "rightThumbProximal": "Thumb0_R",
    "rightThumbIntermediate": "Thumb1_R", "rightThumbDistal": "Thumb2_R",
    "leftIndexProximal": "IndexFinger1_L", "leftIndexIntermediate": "IndexFinger2_L",
    "leftIndexDistal": "IndexFinger3_L",
    "rightIndexProximal": "IndexFinger1_R", "rightIndexIntermediate": "IndexFinger2_R",
    "rightIndexDistal": "IndexFinger3_R",
    "leftMiddleProximal": "MiddleFinger1_L", "leftMiddleIntermediate": "MiddleFinger2_L",
    "leftMiddleDistal": "MiddleFinger3_L",
    "rightMiddleProximal": "MiddleFinger1_R", "rightMiddleIntermediate": "MiddleFinger2_R",
    "rightMiddleDistal": "MiddleFinger3_R",
    "leftRingProximal": "RingFinger1_L", "leftRingIntermediate": "RingFinger2_L",
    "leftRingDistal": "RingFinger3_L",
    "rightRingProximal": "RingFinger1_R", "rightRingIntermediate": "RingFinger2_R",
    "rightRingDistal": "RingFinger3_R",
    "leftLittleProximal": "LittleFinger1_L", "leftLittleIntermediate": "LittleFinger2_L",
    "leftLittleDistal": "LittleFinger3_L",
    "rightLittleProximal": "LittleFinger1_R", "rightLittleIntermediate": "LittleFinger2_R",
    "rightLittleDistal": "LittleFinger3_R",
    "upperChest": "Chest"})

  YupToZup* = [
    [-1.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, 1.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 0.0, 1.0]]

  ## Prefix/suffix clean-ups applied by Cats' "fix armature warning" pass
  ## before bones are matched against its name tables.
  CatsStartsWith: array[27, (string, string)] = [
    ("_", ""), ("ValveBiped_", ""), ("Valvebiped_", ""), ("Bip1_", "Bip_"),
    ("Bip01_", "Bip_"), ("Bip001_", "Bip_"), ("Bip01", ""), ("Bip02_", "Bip_"),
    ("Character1_", ""), ("HLP_", ""), ("JD_", ""), ("JU_", ""),
    ("Armature|", ""), ("Bone_", ""), ("C_", ""), ("Cf_S_", ""), ("Cf_J_", ""),
    ("G_", ""), ("Joint_", ""), ("Def_C_", ""), ("Def_", ""), ("DEF_", ""),
    ("Chr_", ""), ("B_", ""), ("Bip_", "Bip_"), ("bip_", "Bip_"), ("a_", "")]
  CatsEndsWith: array[5, (string, string)] = [
    ("_Bone", ""), ("_Bn", ""), ("_Le", "_L"), ("_Ri", "_R"), ("_", "")]
  CatsReplaces: array[12, (string, string)] = [
    (" ", "_"), ("-", "_"), (".", "_"), (":", "_"), ("____", "_"),
    ("___", "_"), ("__", "_"), ("_Le_", "_L_"), ("_Ri_", "_R_"),
    ("LEFT", "Left"), ("RIGHT", "Right"), ("\t", "")]

proc catsStandardizeName(name: string): string =
  ## Mirror of the name normalisation in Cats-Blender-Plugin's
  ## `fix_armature_warning`: upper-case every underscore separated chunk and
  ## strip the well known prefixes/suffixes.
  var n = name
  var parts = n.split('_')
  for i in 0..<parts.len:
    if parts[i].len > 0:
      parts[i] = toUpperAscii(parts[i][0]) & parts[i][1 .. ^1]
  n = parts.join("_")
  for r in CatsReplaces:
    n = n.replace(r[0], r[1])
  for r in CatsStartsWith:
    if n.startsWith(r[0]):
      n = r[1] & n[r[0].len .. ^1]
      break
  for r in CatsEndsWith:
    if n.endsWith(r[0]):
      n = n[0 ..< n.len - r[0].len] & r[1]
      break
  var seg = n.split('_')
  var leadDigits = seg.len > 1 and seg[0].len > 0
  for ch in seg[0]:
    if ch notin {'0' .. '9'}: leadDigits = false
  if leadDigits:
    n = seg[1 .. ^1].join("_")
  if n.endsWith("S0"): n = n[0 ..< n.len - 2]
  if n.endsWith("_Jnt"): n = n[0 ..< n.len - 4]
  result = n

const
  ## Cats' `bone_rename` entries that apply to plain VRM joint names.  The
  ## table maps a target bone name to the source names it absorbs.
  CatsRename: array[8, (string, array[4, string])] = [
    ("Breast_L", ["J_Sec_L_Bust1", "", "", ""]),
    ("Breast_R", ["J_Sec_R_Bust1", "", "", ""]),
    ("Eye_L", ["Eyes", "J_Adj_L_FaceEye", "", ""]),
    ("Eye_R", ["HL", "J_Adj_R_FaceEye", "", ""]),
    ("Spine", ["BustN", "Bust", "", ""]),
    ("Spine1", ["Waist", "", "", ""]),
    ("Spine2", ["Spine1", "", "", ""]),
    ("Spine3", ["Spine2", "", "", ""])]

proc catsRenameBone(srcName, current: string): string =
  ## Second Cats pass: bones not claimed by the humanoid map are renamed when
  ## their name appears in one of the rename buckets.
  for entry in CatsRename:
    for candidate in entry[1]:
      if candidate.len > 0 and srcName.toLowerAscii == candidate.toLowerAscii:
        return entry[0]
  current

const
  VisemeMixes: array[15, (string, array[2, (string, float64)])] = [
    ("vrc.v_aa", [("a", 0.9998), ("", 0.0)]),
    ("vrc.v_ch", [("ch", 0.9996), ("", 0.0)]),
    ("vrc.v_dd", [("a", 0.3), ("ch", 0.7)]),
    ("vrc.v_ih", [("ch", 0.7), ("o", 0.3)]),
    ("vrc.v_ff", [("a", 0.2), ("ch", 0.4)]),
    ("vrc.v_e", [("a", 0.5), ("ch", 0.2)]),
    ("vrc.v_kk", [("a", 0.7), ("ch", 0.4)]),
    ("vrc.v_nn", [("a", 0.2), ("ch", 0.7)]),
    ("vrc.v_oh", [("a", 0.2), ("o", 0.8)]),
    ("vrc.v_ou", [("o", 0.9994), ("", 0.0)]),
    ("vrc.v_pp", [("a", 0.0004), ("o", 0.0004)]),
    ("vrc.v_rr", [("ch", 0.5), ("o", 0.3)]),
    ("vrc.v_sil", [("a", 0.0002), ("ch", 0.0002)]),
    ("vrc.v_ss", [("ch", 0.8), ("", 0.0)]),
    ("vrc.v_th", [("a", 0.4), ("o", 0.15)])]

  ShapeKeyOrder = ["Basis", "vrc.blink_left", "vrc.blink_right",
    "vrc.lowerlid_left", "vrc.lowerlid_right", "vrc.v_aa", "vrc.v_ch",
    "vrc.v_dd", "vrc.v_e", "vrc.v_ff", "vrc.v_ih", "vrc.v_kk", "vrc.v_nn",
    "vrc.v_oh", "vrc.v_ou", "vrc.v_pp", "vrc.v_rr", "vrc.v_sil", "vrc.v_ss",
    "vrc.v_th", "Basis Original"]

# ---------------------------------------------------------------------------

proc nodeLocal(g: VrmFile, i: int): Mat4 =
  let n = g.nodes[i]
  if n.hasMatrix: return n.matrix
  translation(n.translation) * quatToMat(n.rotation) * scaling(n.scale)

proc nodeWorld(g: VrmFile, i: int): Mat4 =
  var m = nodeLocal(g, i)
  let p = g.nodes[i].parent
  if p >= 0: m = g.nodeWorld(p) * m
  m

# ---- bone helpers ---------------------------------------------------------

proc worldOf(s: seq[Bone], i: int): Mat4 =
  if s[i].parent < 0:
    return s[i].worldRest
  s.worldOf(s[i].parent) * s[i].localRest

proc recomputeWorld(s: var seq[Bone]) =
  for i in 0..<s.len:
    if s[i].parent < 0:
      s[i].worldRest = s[i].localRest
    else:
      s[i].worldRest = s.worldOf(s[i].parent) * s[i].localRest

proc recomputeLocals(s: var seq[Bone]) =
  for i in 0..<s.len:
    let parentM = (if s[i].parent < 0: IdMat4 else: s.worldOf(s[i].parent))
    s[i].localRest = parentM.invertSafe *
      (translation(s[i].head) * quatToMat(s[i].rotQuat) * scaling(s[i].scaleVec))
  s.recomputeWorld()

proc relink(s: var seq[Bone]) =
  for i in 0..<s.len: s[i].children = @[]
  for i in 0..<s.len:
    if s[i].parent >= 0: s[s[i].parent].children.add(i)

proc idxOf(s: seq[Bone], name: string): int =
  for i, b in s:
    if b.name == name: return i
  -1

proc humanIdx(s: seq[Bone], human: string): int =
  for i, b in s:
    if b.humanName == human: return i
  -1

proc setBoneEnds(s: var seq[Bone], i: int, head, tail: Vec3) =
  ## Emulate a Blender edit-mode `head`/`tail` assignment: the bone matrix is
  ## rebuilt from the new direction through `vec_roll_to_mat3`, i.e. with roll 0.
  s[i].head = head
  s[i].tail = tail
  let d = tail - head
  if d.len < 1e-9: return
  # Cats' `fix_armature_warning` drives the roll of every bone to zero except the
  # dozen MMD helper names, and roll 0 is exactly `vec_roll_to_mat3(d, 0)`.
  s[i].rotQuat = matToQuat(boneBasis(d))

proc setTailToChildHead(s: var seq[Bone], i: int) =
  if i < 0 or s[i].children.len == 0: return
  let ch = s[i].children[0]
  s.setBoneEnds(i, s[i].head, s[ch].head)

proc correctBonePositions(s: var seq[Bone]) =
  ## `Common.correct_bone_positions`: snap the tail of a bone onto the head of one
  ## *specific* child.  The child is named, not "whichever child happens to be
  ## first" - Chest for instance also parents the breast and hood bones, and
  ## Cats connects it to the Neck.
  let pairs = [
    ("Chest", "Neck"), ("Neck", "Head"),
    ("Left shoulder", "Left arm"), ("Left arm", "Left elbow"),
    ("Left elbow", "Left wrist"),
    ("Right shoulder", "Right arm"), ("Right arm", "Right elbow"),
    ("Right elbow", "Right wrist"),
    ("Left leg", "Left knee"), ("Left knee", "Left ankle"),
    ("Right leg", "Right knee"), ("Right knee", "Right ankle")]
  for (a, b) in pairs:
    let src = s.idxOf(a)
    let dst = s.idxOf(b)
    if src < 0 or dst < 0: continue
    s.setBoneEnds(src, s[src].head, s[dst].head)
  # The wrists are the one place where "connect to a child" is not a rule: their
  # five children fan out across the palm, so the importer's own node
  # translation - the direction away from the forearm - is what survives.
  for nm in ["Left wrist", "Right wrist"]:
    let i = s.idxOf(nm)
    if i < 0 or s[i].parent < 0: continue
    let away = s[i].head - s[s[i].parent].head
    if away.len < 1e-9: continue
    s.setBoneEnds(i, s[i].head, s[i].head + away)

proc catsFixHips(s: var seq[Bone]) =
  ## Hips placement from `fix_armature_warning` (SDK specification).
  let hips = s.idxOf("Hips")
  let spine = s.idxOf("Spine")
  let leftLeg = s.idxOf("Left leg")
  let rightLeg = s.idxOf("Right knee")
  let rightLegBone = s.idxOf("Right leg")
  if hips < 0 or spine < 0 or leftLeg < 0 or rightLegBone < 0: return
  var head = s[hips].head
  head[0] = (s[rightLegBone].head[0] + s[leftLeg].head[0]) / 2.0
  head[2] = s[leftLeg].head[2] + (s[spine].head[2] - s[leftLeg].head[2]) * 0.33
  if head[2] <= s[rightLegBone].head[2]:
    head[2] = s[rightLegBone].head[2] + 0.1
  var tail = head
  tail[2] = s[spine].head[2]
  if tail[2] < head[2]: tail[2] += 0.1
  s.setBoneEnds(hips, head, tail)
  # make legs bend very slightly forward when they are perfectly vertical
  for (legName, kneeName) in [("Left leg", "Left knee"), ("Right leg", "Right knee")]:
    let leg = s.idxOf(legName)
    let knee = s.idxOf(kneeName)
    if leg < 0 or knee < 0: continue
    var same = true
    for c in 0..<2:
      if round(s[leg].head[c], 4) != round(s[knee].head[c], 4): same = false
    if same:
      var h = s[knee].head
      h[1] -= 0.001
      s.setBoneEnds(knee, h, s[knee].tail)

proc fixZeroLengthBones(s: var seq[Bone]) =
  for i in 0..<s.len:
    if (s[i].head - s[i].tail).len > 0.0001: continue
    s.setBoneEnds(i, s[i].head, s[i].head + [0.0, 0.0, 0.1])

# ---------------------------------------------------------------------------

proc buildBones*(g: VrmFile, s: var Scene) =
  let skin = g.skins[0]
  var jointSet = initOrderedSet[int]()
  for j in skin.joints: jointSet.incl(j)
  for k in 1..<g.skins.len:
    for j in g.skins[k].joints: jointSet.incl(j)

  var humanOfNode = initTable[int, string]()
  for name, idx in g.humanBones:
    if idx >= 0 and jointSet.containsOrIncl(idx):
      humanOfNode[idx] = name

  var nodeToBone = initTable[int, int]()
  var boneNode = newSeq[int]()
  let rootJoint = (if skin.skeleton >= 0: skin.skeleton else: skin.joints[0])

  proc visit(g: VrmFile, s: var Scene, ni: int, jointSet: var OrderedSet[int],
             humanOfNode: Table[int, string], nodeToBone: var Table[int, int]) =
    var b: Bone
    b.srcName = g.nodes[ni].name
    let p = g.nodes[ni].parent
    b.parent = (if p >= 0 and nodeToBone.hasKey(p): nodeToBone[p] else: -1)
    let standardized = catsStandardizeName(b.srcName)
    if humanOfNode.hasKey(ni):
      b.humanName = humanOfNode[ni]
      b.name = HumanNameMap.getOrDefault(b.humanName, standardized)
    else:
      b.name = standardized
    b.name = catsRenameBone(b.srcName, b.name)
    let w = YupToZup * g.nodeWorld(ni)
    b.head = w.getTranslation
    let d = w.decompose
    b.rotQuat = d.quat
    b.scaleVec = d.scale
    b.size = 0.01 * 33.0
    # Blender turns a glTF node into an EditBone, and an EditBone's local Y axis
    # always runs from head to tail - the node basis only supplies the roll.
    # Taking the direction from the node's own Y axis instead points every bone
    # along the node axis, which for an identity-rotation VRM is straight up, so
    # the direction has to come from the child joint.
    let src = quatToMat(b.rotQuat)
    var yAxis = src.col(1).norm
    for c in g.nodes[ni].children:
      if jointSet.containsOrIncl(c):
        let cw = (YupToZup * g.nodeWorld(c)).getTranslation
        let v = cw - b.head
        if v.len > 1e-6: yAxis = v.norm
        break
    b.rotQuat = matToQuat(boneBasis(yAxis))
    # `head` already is the joint position in world space, so the rest matrix
    # can be built right away - later passes (the upper chest merge) need it
    # before the bone hierarchy has been walked.
    b.worldRest = translation(b.head) * quatToMat(b.rotQuat) * scaling(b.scaleVec)
    nodeToBone[ni] = s.bones.len
    boneNode.add(ni)
    s.bones.add(b)
    for c in g.nodes[ni].children:
      let ci = c
      if jointSet.containsOrIncl(ci): visit(g, s, c, jointSet, humanOfNode, nodeToBone)

  if jointSet.containsOrIncl(rootJoint): visit(g, s, rootJoint, jointSet, humanOfNode, nodeToBone)
  else:
    for j in skin.joints: visit(g, s, j, jointSet, humanOfNode, nodeToBone)

  # drop the dummy skeleton root bone (identity transform, single child and
  # not a humanoid bone) - matches the glTF importer with join_meshes disabled
  s.bones.relink()
  if s.bones.len > 1 and s.bones[0].parent < 0 and s.bones[0].children.len == 1 and
     s.bones[0].humanName == "" and s.bones[0].head.len < 1e-6:
    let keep = s.bones[0].children[0]
    var nb = newSeq[Bone]()
    for i in 1..<s.bones.len:
      var b = s.bones[i]
      if i == keep: b.parent = -1
      else: b.parent = b.parent - 1
      nb.add(b)
    s.bones = nb
    s.bones.relink()
    # vertices weighted to the dummy root follow its only child
    for ni in nodeToBone.keys:
      nodeToBone[ni] = (if nodeToBone[ni] == 0: 0 else: nodeToBone[ni] - 1)

  # merge upper chest into chest (keep_upper_chest = False)
  var upperIdx = -1
  for i, b in s.bones:
    if b.humanName == "upperChest": upperIdx = i
  if upperIdx >= 0 and s.bones[upperIdx].parent >= 0:
    let dead = upperIdx
    let parent = s.bones[dead].parent
    # keep the children at their world position
    for k in s.bones[dead].children:
      let kw = s.bones[k].worldRest
      s.bones[k].head = kw.getTranslation
    var nb = newSeq[Bone]()
    for i in 0..<s.bones.len:
      if i == dead: continue
      var b = s.bones[i]
      if b.parent == dead: b.parent = parent
      elif b.parent > dead: b.parent = b.parent - 1
      nb.add(b)
    s.bones = nb
    s.bones.relink()
    # `keep_upper_chest = False`: the deleted bone's vertex group is merged
    # into its parent, so its vertices keep being deformed - by the chest.
    for ni in nodeToBone.keys:
      let old = nodeToBone[ni]
      nodeToBone[ni] = (if old == dead: parent
                        elif old > dead: old - 1
                        else: old)

  s.nodeBoneMap = nodeToBone

  # unique names
  var used = initOrderedSet[string]()
  for i in 0..<s.bones.len:
    var nm = s.bones[i].name
    if nm in used:
      var k = 1
      while (nm & "." & $k) in used: inc k
      nm = nm & "." & $k
    used.incl nm
    s.bones[i].name = nm

  # tails.  Blender's glTF importer derives each tail from the bone's children;
  # `correct_bone_positions` (plus the hips special case) then moves a few of
  # them explicitly.  See the note in `correctBonePositions` about
  # AUTO_BONE_CONNECTION_DISTANCE.  Assigning a tail in edit mode also rebuilds
  # the bone matrix, which matters for the leaf bones: they have no child to
  # take the direction from, so without it they would keep the +Z axis the node
  # basis handed them.
  s.bones.relink()
  for i in 0..<s.bones.len:
    if s.bones[i].children.len > 0:
      s.bones.setBoneEnds(i, s.bones[i].head, s.bones[s.bones[i].children[0]].head)
    elif s.bones[i].parent >= 0:
      s.bones.setBoneEnds(i, s.bones[i].head,
        s.bones[i].head +
        (s.bones[i].head - s.bones[s.bones[i].parent].head).norm * 0.01)
    else:
      s.bones.setBoneEnds(i, s.bones[i].head, s.bones[i].head + [0.0, 0.0, 0.01])

  # edit-mode clean-ups performed by Cats' `fix_armature_warning`
  # (head straightening, tail snapping, hips placement, degenerate bones)
  let head = s.bones.idxOf("Head")
  if head >= 0:
    var t = s.bones[head].tail
    t[0] = s.bones[head].head[0]
    t[1] = s.bones[head].head[1]
    if t[2] < s.bones[head].head[2]: t[2] = s.bones[head].head[2] + 0.1
    s.bones.setBoneEnds(head, s.bones[head].head, t)
  s.bones.correctBonePositions()
  s.bones.catsFixHips()
  s.bones.fixZeroLengthBones()
  s.bones.recomputeLocals()

# ---------------------------------------------------------------------------

proc buildMeshes*(g: VrmFile, s: var Scene) =
  # The Blender object name comes from the glTF node, the mesh data name from
  # the glTF mesh.
  var meshObjName = initTable[int, string]()
  for nd in g.nodes:
    if nd.mesh >= 0 and not meshObjName.hasKey(nd.mesh):
      meshObjName[nd.mesh] = nd.name
  for mi, mesh in g.meshes:
    if mesh.primitives.len == 0: continue
    var m: Mesh
    m.name = mesh.name
    m.objName = meshObjName.getOrDefault(mi, mesh.name)
    m.srcMesh = mi
    let pr = mesh.primitives[0]
    let pos = g.readV3(pr.attributes.getOrDefault("POSITION", -1))
    let nrm = g.readV3(pr.attributes.getOrDefault("NORMAL", -1))
    let uvAcc = pr.attributes.getOrDefault("TEXCOORD_0", -1)
    # glTF stores V pointing up, Blender and therefore FBX store it pointing
    # down, and Blender's glTF importer flips it on the way in.  Without the
    # flip the alpha channel is sampled from mirrored positions, which is
    # invisible on an opaque material but makes faces vanish in cutout mode.
    var uv = (if uvAcc >= 0: g.readV2(uvAcc) else: newSeq[array[2, float64]]())
    for t in 0..<uv.len:
      uv[t][1] = 1.0 - uv[t][1]
    let jAcc = pr.attributes.getOrDefault("JOINTS_0", -1)
    let wAcc = pr.attributes.getOrDefault("WEIGHTS_0", -1)
    let joints = (if jAcc >= 0: g.readVec(jAcc, 4) else: @[])
    let weights = (if wAcc >= 0: g.readVec(wAcc, 4) else: @[])

    let nodeToBone = s.nodeBoneMap

    let nv = pos.len
    m.verts = newSeq[float64](nv * 3)
    m.normals = newSeq[float64](nv * 3)
    for i in 0..<nv:
      let p = YupToZup * [pos[i][0], pos[i][1], pos[i][2], 1.0]
      m.verts[i * 3] = p[0]; m.verts[i * 3 + 1] = p[1]; m.verts[i * 3 + 2] = p[2]
      if i < nrm.len:
        let n = YupToZup * [nrm[i][0], nrm[i][1], nrm[i][2], 0.0]
        m.normals[i * 3] = n[0]; m.normals[i * 3 + 1] = n[1]; m.normals[i * 3 + 2] = n[2]

    m.weights = newSeq[seq[tuple[idx: int, w: float64]]](nv)
    if joints.len >= nv * 4 and weights.len >= nv * 4:
      for i in 0..<nv:
        var order: seq[int] = @[]
        var acc: seq[float64] = @[]
        for k in 0..<4:
          let w = weights[i * 4 + k]
          if w > 0.0:
            let ni = int(joints[i * 4 + k])
            if not nodeToBone.hasKey(ni): continue
            # several joints can end up on the same bone (merged bones)
            let b = nodeToBone[ni]
            var at = order.len
            for t in 0..<order.len:
              if order[t] == b: at = t; break
            if at == order.len:
              order.add(b)
              acc.add(w)
            else:
              acc[at] += w
        var lst: seq[tuple[idx: int, w: float64]] = @[]
        for t in 0..<order.len: lst.add((idx: order[t], w: acc[t]))
        m.weights[i] = lst

    var lnVals = newSeq[float64]()
    var lnIdx = initOrderedTable[int, int]()
    var uvVals = newSeq[float64]()
    var uvIdx = initOrderedTable[int, int]()
    for p in mesh.primitives:
      let idx = g.readIndices(p.indices)
      m.matIndices.add(p.material)
      # glTF has no polygon terminators: with mode TRIANGLES the index buffer is
      # simply a flat run of triangles.
      let perPoly = (if p.mode == 4: 3 elif p.mode == 5 or p.mode == 6: 4 else: 3)
      var i = 0
      while i + perPoly <= idx.len:
        let count = perPoly
        if count >= 3:
          for t in 0..<count:
            let vi = idx[i + t]
            m.loops.add(int32(if t == count - 1: (not vi) else: vi))
            var ni = lnIdx.getOrDefault(vi, -1)
            if ni < 0:
              ni = lnVals.len div 3
              lnIdx[vi] = ni
              for c in 0..<3: lnVals.add(m.normals[vi * 3 + c])
            m.loopNormalIdx.add(int32(ni))
            let ukey = (if vi < uv.len: (vi shl 20) or int(uv[vi][0] * 1000.0) else: vi)
            var ui = uvIdx.getOrDefault(ukey, -1)
            if ui < 0:
              ui = uvVals.len div 2
              uvIdx[ukey] = ui
              if vi < uv.len:
                uvVals.add(uv[vi][0]); uvVals.add(uv[vi][1])
              else:
                uvVals.add(0.0); uvVals.add(0.0)
            m.loopUvIdx.add(int32(ui))
          # `LayerElementMaterial/Materials` has one entry per polygon and
          # indexes the material list connected to *this* mesh, so store the
          # primitive's position inside `matIndices`.
          m.polyMat.add(int32(m.matIndices.high))
        i += count
    m.loopNormals = lnVals
    m.loopUv = uvVals

    # FBX `Edges` holds the *loop* index of the first loop of every unique edge
    # (the edge runs from that loop's vertex to the next one on the polygon),
    # in order of first occurrence - mirroring Blender's exporter.
    var edgeSeen = initOrderedSet[string]()
    var loopIdx = newSeq[int](m.loops.len)
    for i, v in m.loops:
      loopIdx[i] = (if v < 0: (not v) else: v)
    var polyStart = 0
    for i in 0..<loopIdx.len:
      if i > polyStart and m.loops[i - 1] < 0: polyStart = i
      let a = loopIdx[i]
      let b = loopIdx[(if m.loops[i] < 0: polyStart else: i + 1)]
      if a == b: continue
      let key = (if a < b: $a & "_" & $b else: $b & "_" & $a)
      if key notin edgeSeen:
        edgeSeen.incl key
        m.edges.add(int32(i))

    for ti in 0..<pr.targetCount:
      let acc = pr.targetPos[ti]
      if acc < 0: continue
      let deltas = g.readV3(acc)
      var moved = false
      for d in deltas:
        if d[0] != 0.0 or d[1] != 0.0 or d[2] != 0.0: moved = true
      # Shape keys with no displacement are dropped, as Blender's importer does.
      if not moved: continue
      var sk: ShapeKey
      sk.name = (if ti < mesh.targetNames.len: mesh.targetNames[ti] else: "target" & $ti)
      sk.positions = newSeq[float64](nv * 3)
      sk.indices = @[]
      for i in 0..<nv:
        if i >= deltas.len: break
        let d = YupToZup * [deltas[i][0], deltas[i][1], deltas[i][2], 0.0]
        if d[0] != 0.0 or d[1] != 0.0 or d[2] != 0.0:
          sk.indices.add(int32(i))
        sk.positions[i * 3] = m.verts[i * 3] + d[0]
        sk.positions[i * 3 + 1] = m.verts[i * 3 + 1] + d[1]
        sk.positions[i * 3 + 2] = m.verts[i * 3 + 2] + d[2]
      m.shapes.add(sk)
    s.meshes.add(m)

# ---------------------------------------------------------------------------
# Cats viseme shapes
# ---------------------------------------------------------------------------

proc addVisemes*(s: var Scene, mouthA, mouthO, mouthCh: string) =
  for mi in 0..<s.meshes.len:
    if s.meshes[mi].shapes.len == 0: continue
    var byName = initTable[string, int]()
    for i, sk in s.meshes[mi].shapes: byName[sk.name] = i
    let ia = byName.getOrDefault(mouthA, -1)
    let io = byName.getOrDefault(mouthO, -1)
    let ic = byName.getOrDefault(mouthCh, -1)
    if ia < 0 or io < 0 or ic < 0: continue
    let n = s.meshes[mi].verts.len div 3
    var created: seq[ShapeKey] = @[]
    for (vname, mix) in VisemeMixes:
      var sk: ShapeKey
      sk.name = vname
      sk.positions = newSeq[float64](n * 3)
      for i in 0..<n:
        for c in 0..<3:
          var v = s.meshes[mi].verts[i * 3 + c].float64
          for j in 0..1:
            let (which, w) = mix[j]
            if w == 0.0: continue
            let idx = (case which
                       of "a": ia
                       of "o": io
                       else: ic)
            v += w * (s.meshes[mi].shapes[idx].positions[i * 3 + c] -
                      s.meshes[mi].verts[i * 3 + c])
          sk.positions[i * 3 + c] = v
      created.add(sk)
    # eyelid shapes (vrc.lowerlid_*): no deformation, kept for compatibility
    for side in ["left", "right"]:
      var sk: ShapeKey
      sk.name = "vrc.lowerlid_" & side
      sk.positions = s.meshes[mi].verts
      created.add(sk)
    # merge and sort like Common.sort_shape_keys()
    var all: seq[ShapeKey] = @[]
    for nm in ShapeKeyOrder:
      for sk in created:
        if sk.name == nm: all.add(sk)
    for sk in s.meshes[mi].shapes:
      var dup = false
      for a in all:
        if a.name == sk.name: dup = true
      if not dup: all.add(sk)
    s.meshes[mi].shapes = all

# ---------------------------------------------------------------------------
# Eye tracking bones
# ---------------------------------------------------------------------------

proc copyEyeWeights(s: var Scene, srcBone, dstBone: int)

proc eyeVertexGroupCentre(s: Scene, meshName, boneName: string): Vec3 =
  ## Cats' `Common.find_center_vector_of_vertex_group`: the average position of
  ## every vertex that carries weight in the named group.  The scene has already
  ## been through `transform_apply`, so mesh space and armature space coincide
  ## and `mesh.matrix_world` is the identity.
  var mi = -1
  for i, m in s.meshes:
    if m.objName == meshName or m.name == meshName or
       m.name.startsWith(meshName & " "):
      mi = i
      break
  if mi < 0: return [0.0, 0.0, 0.0]
  let bi = s.bones.idxOf(boneName)
  if bi < 0: return [0.0, 0.0, 0.0]
  let m = s.meshes[mi]
  var total: Vec3
  var n = 0
  for i in 0..<(m.verts.len div 3):
    for (b, w) in m.weights[i]:
      if b == bi and w > 0.0:
        total = total + [m.verts[i * 3], m.verts[i * 3 + 1], m.verts[i * 3 + 2]]
        inc n
        break
  if n == 0: return [0.0, 0.0, 0.0]
  total * (1.0 / n.float64)

proc addEyeTracking*(s: var Scene, leftName, rightName: string) =
  ## Cats' `create_eye_tracking`: a fresh `LeftEye`/`RightEye` bone parented to
  ## Head, placed by `fix_eye_position` - 20% of the way from the old eye bone
  ## head towards the centre of that bone's vertex group, then pointing straight
  ## up (`new_eye.tail[z] = new_eye.head[z] + 0.1`, everything else equal to the
  ## head).  `scene.eye_distance` defaults to 0.8, hence the 0.2 factor.
  let head = s.bones.humanIdx("head")
  if head < 0: return
  const scale = 1.0 - 0.8      # Cats: `-context.scene.eye_distance + 1`
  # Cats names the new bones `LeftEye`/`RightEye` unconditionally and only uses
  # `scene.eye_left`/`eye_right` to locate the old ones it copies from.
  for (oldName, nm) in [(leftName, "LeftEye"), (rightName, "RightEye")]:
    let src = s.bones.idxOf(oldName)
    if src < 0: continue
    let centre = eyeVertexGroupCentre(s, "Face", s.bones[src].name)
    var b: Bone
    b.name = nm
    b.srcName = ""
    b.parent = head
    b.head = s.bones[src].head
    for c in 0..<3:
      b.head[c] += scale * (centre[c] - s.bones[src].head[c])
    b.tail = b.head
    b.tail[2] = b.head[2] + 0.1
    b.rotQuat = matToQuat(boneBasis(b.tail - b.head))
    b.scaleVec = [1.0, 1.0, 1.0]
    b.size = 0.01 * 33.0
    let newIdx = s.bones.len
    s.bones.add(b)
    # Cats copies the old eye vertex group onto the new tracking bones.
    copyEyeWeights(s, src, newIdx)
  s.bones.relink()
  s.bones.recomputeLocals()

proc orientEyeBones*(s: var Scene, leftName, rightName: string) =
  ## Cats' `av3_orient_eye_bones` (`bpy.ops.cats_eyes.av3_orient_eye_bones`):
  ## point both eye bones straight up with zero roll, which is exactly a 90
  ## degree rotation about X, so both eyes can share one tracking rotation.
  for nm in [leftName, rightName]:
    let i = s.bones.idxOf(nm)
    if i < 0: continue
    s.bones[i].tail = s.bones[i].head + [0.0, 0.0, 0.1]
    s.bones[i].rotQuat = matToQuat(boneBasis([0.0, 0.0, 1.0]))
  s.bones.relink()
  s.bones.recomputeLocals()

proc copyEyeWeights(s: var Scene, srcBone, dstBone: int) =
  ## Duplicate a vertex group onto the new eye tracking bone (Cats'
  ## `copy_vertex_group`), replacing any weights the bone already has.
  for mi in 0..<s.meshes.len:
    let m = addr s.meshes[mi]
    for vi in 0..<m[].weights.len:
      var kept: seq[tuple[idx: int, w: float64]] = @[]
      for e in m[].weights[vi]:
        if e.idx != dstBone: kept.add(e)
      m[].weights[vi] = kept
    for vi in 0..<m[].weights.len:
      for e in m[].weights[vi]:
        if e.idx == srcBone:
          m[].weights[vi].add((idx: dstBone, w: e.w))
          break

# ---------------------------------------------------------------------------
# T pose
# ---------------------------------------------------------------------------

type
  ## A humanoid bone referenced by the names it can have in VRM 0.x and 1.x.
  BoneRef* = object
    vrm0: string
    vrm1: string

  ChainKind = enum ckSingle, ckFingers

  Chain = object
    dir: Vec3
    kind: ChainKind
    bones: array[3, BoneRef]     ## single-child chains, root -> tip
    parentHuman: BoneRef         ## finger chains: the hand bone
    children: array[4, BoneRef]  ## finger chains: the four proximal bones

const
  r2 = sqrt(0.5)

proc chainList(): seq[Chain] =
  ## Order and directions of the T-pose chain corrections, mirroring
  ## `set_estimated_humanoid_t_pose` in the VRM-Addon.
  result = @[
    Chain(dir: [-1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightUpperArm", vrm1: "rightUpperArm"),
              BoneRef(vrm0: "rightLowerArm", vrm1: "rightLowerArm"),
              BoneRef(vrm0: "rightHand", vrm1: "rightHand")]),
    Chain(dir: [-1.0, 0.0, 0.0], kind: ckFingers,
      parentHuman: BoneRef(vrm0: "rightHand", vrm1: "rightHand"),
      children: [BoneRef(vrm0: "rightIndexProximal", vrm1: "rightIndexProximal"),
                 BoneRef(vrm0: "rightMiddleProximal", vrm1: "rightMiddleProximal"),
                 BoneRef(vrm0: "rightRingProximal", vrm1: "rightRingProximal"),
                 BoneRef(vrm0: "rightLittleProximal", vrm1: "rightLittleProximal")]),
    Chain(dir: [-r2, -r2, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightThumbProximal", vrm1: "rightThumbMetacarpal"),
              BoneRef(vrm0: "rightThumbIntermediate", vrm1: "rightThumbProximal"),
              BoneRef(vrm0: "rightThumbDistal", vrm1: "rightThumbDistal")]),
    Chain(dir: [-1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightIndexProximal", vrm1: "rightIndexProximal"),
              BoneRef(vrm0: "rightIndexIntermediate", vrm1: "rightIndexIntermediate"),
              BoneRef(vrm0: "rightIndexDistal", vrm1: "rightIndexDistal")]),
    Chain(dir: [-1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightMiddleProximal", vrm1: "rightMiddleProximal"),
              BoneRef(vrm0: "rightMiddleIntermediate", vrm1: "rightMiddleIntermediate"),
              BoneRef(vrm0: "rightMiddleDistal", vrm1: "rightMiddleDistal")]),
    Chain(dir: [-1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightRingProximal", vrm1: "rightRingProximal"),
              BoneRef(vrm0: "rightRingIntermediate", vrm1: "rightRingIntermediate"),
              BoneRef(vrm0: "rightRingDistal", vrm1: "rightRingDistal")]),
    Chain(dir: [-1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightLittleProximal", vrm1: "rightLittleProximal"),
              BoneRef(vrm0: "rightLittleIntermediate", vrm1: "rightLittleIntermediate"),
              BoneRef(vrm0: "rightLittleDistal", vrm1: "rightLittleDistal")]),
    Chain(dir: [0.0, 0.0, -1.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "rightUpperLeg", vrm1: "rightUpperLeg"),
              BoneRef(vrm0: "rightLowerLeg", vrm1: "rightLowerLeg"),
              BoneRef(vrm0: "rightFoot", vrm1: "rightFoot")]),
    Chain(dir: [1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftUpperArm", vrm1: "leftUpperArm"),
              BoneRef(vrm0: "leftLowerArm", vrm1: "leftLowerArm"),
              BoneRef(vrm0: "leftHand", vrm1: "leftHand")]),
    Chain(dir: [1.0, 0.0, 0.0], kind: ckFingers,
      parentHuman: BoneRef(vrm0: "leftHand", vrm1: "leftHand"),
      children: [BoneRef(vrm0: "leftIndexProximal", vrm1: "leftIndexProximal"),
                 BoneRef(vrm0: "leftMiddleProximal", vrm1: "leftMiddleProximal"),
                 BoneRef(vrm0: "leftRingProximal", vrm1: "leftRingProximal"),
                 BoneRef(vrm0: "leftLittleProximal", vrm1: "leftLittleProximal")]),
    Chain(dir: [r2, -r2, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftThumbProximal", vrm1: "leftThumbMetacarpal"),
              BoneRef(vrm0: "leftThumbIntermediate", vrm1: "leftThumbProximal"),
              BoneRef(vrm0: "leftThumbDistal", vrm1: "leftThumbDistal")]),
    Chain(dir: [1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftIndexProximal", vrm1: "leftIndexProximal"),
              BoneRef(vrm0: "leftIndexIntermediate", vrm1: "leftIndexIntermediate"),
              BoneRef(vrm0: "leftIndexDistal", vrm1: "leftIndexDistal")]),
    Chain(dir: [1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftMiddleProximal", vrm1: "leftMiddleProximal"),
              BoneRef(vrm0: "leftMiddleIntermediate", vrm1: "leftMiddleIntermediate"),
              BoneRef(vrm0: "leftMiddleDistal", vrm1: "leftMiddleDistal")]),
    Chain(dir: [1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftRingProximal", vrm1: "leftRingProximal"),
              BoneRef(vrm0: "leftRingIntermediate", vrm1: "leftRingIntermediate"),
              BoneRef(vrm0: "leftRingDistal", vrm1: "leftRingDistal")]),
    Chain(dir: [1.0, 0.0, 0.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftLittleProximal", vrm1: "leftLittleProximal"),
              BoneRef(vrm0: "leftLittleIntermediate", vrm1: "leftLittleIntermediate"),
              BoneRef(vrm0: "leftLittleDistal", vrm1: "leftLittleDistal")]),
    Chain(dir: [0.0, 0.0, -1.0], kind: ckSingle,
      bones: [BoneRef(vrm0: "leftUpperLeg", vrm1: "leftUpperLeg"),
              BoneRef(vrm0: "leftLowerLeg", vrm1: "leftLowerLeg"),
              BoneRef(vrm0: "leftFoot", vrm1: "leftFoot")])]

proc resolveBone(s: seq[Bone], r: BoneRef): int =
  ## Humanoid bone index for either specification version.
  let i = s.humanIdx(r.vrm0)
  if i >= 0: return i
  s.humanIdx(r.vrm1)

const TposeEps = 2.220446049250313e-16

proc poseMatrices(bones: seq[Bone], poseQuat: seq[Quat]): seq[Mat4] =
  ## Pose bone matrices in armature space for the given basis rotations.
  result = newSeq[Mat4](bones.len)
  for i in 0..<bones.len:
    let parentM = (if bones[i].parent < 0: IdMat4 else: result[bones[i].parent])
    result[i] = parentM * bones[i].localRest * quatToMat(poseQuat[i])

proc estimateTPose*(s: var Scene) =
  ## Reproduce the VRM-Addon's estimated humanoid T-pose: start from the rest
  ## pose and rotate the specified chains so the limbs follow the VRM spec
  ## directions.
  var poseQuat = newSeq[Quat](s.bones.len)
  for i in 0..<poseQuat.len: poseQuat[i] = [0.0, 0.0, 0.0, 1.0]
  var posed = poseMatrices(s.bones, poseQuat)

  proc applyRotation(bones: seq[Bone], quat: var seq[Quat],
                     posed: var seq[Mat4], bone: int, vFrom, vTo: Vec3) =
    if vFrom.len * vFrom.len < TposeEps or vTo.len * vTo.len < TposeEps: return
    quat[bone] = quatMul(rotationBetween(vFrom, vTo), quat[bone])
    posed = poseMatrices(bones, quat)

  for ch in chainList():
    if ch.kind == ckSingle:
      var idxs: seq[int] = @[]
      for r in ch.bones:
        let i = s.bones.resolveBone(r)
        if i >= 0: idxs.add(i)
      if idxs.len < 2: continue
      # walk up from the tip to collect the actual chain
      var chained: seq[int] = @[]
      var cur = idxs[^1]
      while true:
        chained.insert(cur, 0)
        if cur == idxs[0]: break
        if s.bones[cur].parent < 0: break
        cur = s.bones[cur].parent
      for k in 0..<(chained.len - 1):
        let bw = posed[chained[k]]
        let cw = posed[chained[k + 1]]
        let bt = bw.getTranslation
        let boneLen = (cw.getTranslation - bt).len
        let inv = bw.invertSafe
        applyRotation(s.bones, poseQuat, posed, chained[k],
                      inv * cw.getTranslation, inv * (bt + ch.dir * boneLen))
    else:
      var idxs: seq[int] = @[]
      for r in ch.children:
        let i = s.bones.resolveBone(r)
        if i >= 0: idxs.add(i)
      if idxs.len == 0: continue
      let pIdx = s.bones.resolveBone(ch.parentHuman)
      if pIdx < 0: continue
      var avg: Vec3 = [0.0, 0.0, 0.0]
      for i in idxs: avg = avg + posed[i].getTranslation
      avg = avg * (1.0 / idxs.len.float64)
      let bw = posed[pIdx]
      let bt = bw.getTranslation
      let inv = bw.invertSafe
      # keep the bone's own height, align the horizontal offset with `dir`
      applyRotation(s.bones, poseQuat, posed, pIdx,
                    inv * [avg[0], bt[1], avg[2]], inv * (bt + ch.dir))

  s.poseWorld = posed

proc applyPoseToRest*(s: var Scene) =
  ## Bake the estimated pose into the rest pose and deform the meshes.  This is
  ## `bpy.ops.pose.armature_apply`: the head moves to the posed head and the bone
  ## axis follows the pose, but the bone *length* is kept, so the tail travels
  ## along the new axis instead of being snapped back onto a child head.
  for i in 0..<s.bones.len:
    let rest = s.bones[i].worldRest
    let boneLen = (s.bones[i].tail - s.bones[i].head).len
    let d = s.poseWorld[i].decompose
    s.bones[i].head = s.poseWorld[i].getTranslation
    s.bones[i].rotQuat = d.quat
    s.bones[i].scaleVec = d.scale
    s.bones[i].tail = s.bones[i].head + quatToMat(d.quat).col(1) * boneLen
    s.bones[i].localRest = (if s.bones[i].parent < 0: IdMat4
                            else: s.bones[s.bones[i].parent].worldRest.invertSafe) *
      (translation(s.bones[i].head) * quatToMat(s.bones[i].rotQuat) *
       scaling(s.bones[i].scaleVec))
  s.bones.relink()

  var deltas = newSeq[Mat4](s.bones.len)
  for i in 0..<s.bones.len:
    deltas[i] = s.poseWorld[i] * s.bones[i].worldRest.invertSafe
  for mi in 0..<s.meshes.len:
    let m = addr s.meshes[mi]
    for i in 0..<(m[].verts.len div 3):
      let p = [m[].verts[i * 3], m[].verts[i * 3 + 1], m[].verts[i * 3 + 2]]
      var acc = [0.0, 0.0, 0.0]
      var total = 0.0
      for (bi, w) in m[].weights[i]:
        let t = deltas[bi] * [p[0], p[1], p[2], 1.0]
        acc = acc + [t[0], t[1], t[2]] * w
        total += w
      if total > 0.0:
        m[].verts[i * 3] = acc[0] / total
        m[].verts[i * 3 + 1] = acc[1] / total
        m[].verts[i * 3 + 2] = acc[2] / total
    for skIdx in 0..<m[].shapes.len:
      let sk = addr m[].shapes[skIdx]
      for i in 0..<(sk[].positions.len div 3):
        let p = [sk[].positions[i * 3], sk[].positions[i * 3 + 1],
                 sk[].positions[i * 3 + 2]]
        var acc = [0.0, 0.0, 0.0]
        var total = 0.0
        for (bi, w) in m[].weights[i]:
          let t = deltas[bi] * [p[0], p[1], p[2], 1.0]
          acc = acc + [t[0], t[1], t[2]] * w
          total += w
        if total > 0.0:
          sk[].positions[i * 3] = acc[0] / total
          sk[].positions[i * 3 + 1] = acc[1] / total
          sk[].positions[i * 3 + 2] = acc[2] / total

proc fixSpineBones*(s: var Scene) =
  ## The original script flattens the Spine/Chest/Neck chain on the Y axis.
  let sp = s.bones.idxOf("Spine")
  let ch = s.bones.idxOf("Chest")
  let nk = s.bones.idxOf("Neck")
  if sp < 0 or ch < 0 or nk < 0: return
  let tail = s.bones[sp].tail[1]
  var h, t: Vec3
  # Spine.head.y = Spine.tail.y
  h = s.bones[sp].head; h[1] = tail
  t = s.bones[sp].tail; t[1] = tail
  s.bones.setBoneEnds(sp, h, t)
  # Chest.tail.y = tail; Chest.head.y = 0
  t = s.bones[ch].tail; t[1] = tail
  h = s.bones[ch].head; h[1] = 0.0
  s.bones.setBoneEnds(ch, h, t)
  # Neck.tail.y = 0; Neck.head.y = 0
  t = s.bones[nk].tail; t[1] = 0.0
  h = s.bones[nk].head; h[1] = 0.0
  s.bones.setBoneEnds(nk, h, t)
  s.bones.recomputeLocals()

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# materials / textures
# ---------------------------------------------------------------------------

proc buildMaterials(s: var Scene, g: VrmFile) =
  ## Collect the MToon materials and their texture images, naming the images
  ## the same way the VRM importer / Blender does.
  var fbmBase = s.fbmBase
  var fbmRel = fbmName(fbmBase)
  var images = addr s.images
  var imageByIndex = initTable[int, string]()
  var usedNames = initOrderedSet[string]()
  var counter = 0
  proc imgNameFor(idx: int, preferred: string): string =
    if imageByIndex.hasKey(idx): return imageByIndex[idx]
    var nm = preferred
    if nm.len == 0:
      counter += 1
      nm = "_" & align($counter, 2, '0')
    while nm in usedNames:
      counter += 1
      nm = "_" & align($counter, 2, '0')
    usedNames.incl nm
    var t: Texture
    t.name = nm
    t.data = g.images[idx].data
    t.fileName = fbmBase & nm & ".png"
    t.relFileName = fbmRel & "\\" & nm & ".png"
    images[].add(t)
    imageByIndex[idx] = nm
    nm

  for mt in g.materials:
    var m: MatDef
    m.name = mt.name
    m.diffuse = [mt.baseColorFactor[0], mt.baseColorFactor[1], mt.baseColorFactor[2]]
    # Scene world colour as seen by Blender's FBX material exporter.
    m.ambient = 0.05087608844041824
    # MToon stores its colours as sRGB; Blender's node sockets are linear and
    # the FBX exporter writes those raw, hence the 2.2 gamma.
    for c in 0..<3:
      m.emission[c] = pow(mt.emissionColor[c], 2.2)
      if m.emission[c] < 0.0: m.emission[c] = 0.0
    # slot 0 = base colour, 1 = normal map, 2 = emission, 3 = alpha
    for si in 0..3:
      var ti = mt.mtoonTexIndices[si]
      if si == 3:
        # MToon samples alpha from the base colour texture; only blended
        # materials expose a separate TransparencyFactor link.
        if mt.blendMode != 2 or ti < 0: continue
        ti = mt.mtoonTexIndices[0]
      if ti < 0 or ti >= g.textures.len: continue
      let srcImg = g.textures[ti].source
      if srcImg < 0 or srcImg >= g.images.len: continue
      var preferred = if si < mt.mtoonTexNames.len: mt.mtoonTexNames[si] else: ""
      if preferred.len == 0:
        preferred = g.images[srcImg].name
      # the emission/normal placeholders of the VRM importer
      if si == 1 and preferred.len == 0:
        preferred = "Shader_NoneNormal"
      if si == 2 and preferred.len == 0:
        preferred = "Shader_NoneBlack"
      let nm = imgNameFor(srcImg, preferred)
      case si
      of 0: m.baseTex = nm
      of 1: m.normalTex = nm
      of 2: m.emissionTex = nm
      else: m.alphaTex = nm
    s.materials.add(m)

# ---------------------------------------------------------------------------

proc sparsifyShapes(s: var Scene) =
  ## A blend shape channel lists the vertex indices it moves plus the position
  ## of exactly those vertices (`Vertices` has 3 entries per `Indexes` entry,
  ## `Normals` as many as `Vertices`).  Everything above builds shape keys as
  ## full-length position arrays, so convert them here - after the T-pose has
  ## been baked in - and rebuild the sparse index list.
  ##
  ## The stored positions are **offsets from the base mesh**, not absolute
  ## positions: that is how Blender keeps `ShapeKey.data` and what its FBX
  ## exporter writes.  Writing absolute positions makes every vertex jump to
  ## its base location as soon as the weight goes above zero, which stretches
  ## the whole mesh instead of deforming it.
  for mi in 0..<s.meshes.len:
    let base = s.meshes[mi].verts
    let n = base.len div 3
    for skIdx in 0..<s.meshes[mi].shapes.len:
      let src = s.meshes[mi].shapes[skIdx].positions
      var idx: seq[int32] = @[]
      var pos: seq[float64] = @[]
      for i in 0..<n:
        if (i + 1) * 3 > src.len: break
        # Blender keeps every vertex whose shape position differs from the base
        # mesh, so compare exactly rather than with an epsilon: a threshold
        # large enough to drop float noise also swallows the small but genuine
        # displacements of e.g. vrc.v_pp.
        if src[i * 3] == base[i * 3] and
           src[i * 3 + 1] == base[i * 3 + 1] and
           src[i * 3 + 2] == base[i * 3 + 2]:
          continue
        idx.add int32(i)
        pos.add src[i * 3] - base[i * 3]
        pos.add src[i * 3 + 1] - base[i * 3 + 1]
        pos.add src[i * 3 + 2] - base[i * 3 + 2]
      if idx.len == 0:
        # A shape key with no displacement still has to be a valid FBX shape:
        # keep a single untouched vertex, which is what Blender writes for the
        # neutral `vrc.lowerlid_*` shapes.
        idx = @[int32(0)]
        pos = @[0.0, 0.0, 0.0]   # neutral: zero offset, as Blender writes
      s.meshes[mi].shapes[skIdx].indices = idx
      s.meshes[mi].shapes[skIdx].positions = pos

proc buildScene*(g: VrmFile, fbmBase: string): Scene =
  var s: Scene
  new(s)
  s.fbmBase = fbmBase
  buildBones(g, s)
  buildMeshes(g, s)
  addVisemes(s, "Fcl_MTH_A", "Fcl_MTH_O", "Fcl_MTH_I")
  addEyeTracking(s, "Eye_L", "Eye_R")
  orientEyeBones(s, "Eye_L", "Eye_R")
  estimateTPose(s)
  applyPoseToRest(s)
  fixSpineBones(s)
  sparsifyShapes(s)
  buildMaterials(s, g)
  s
