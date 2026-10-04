## Binary FBX (7.4 / version 7400) writer, byte compatible with Blender's
## `io_scene_fbx` + `encode_bin` output.

type
  PropType* = enum
    ptBool = 'C', ptChar = 'c', ptInt8 = 'b', ptInt16 = 'h', ptInt32 = 'I',
    ptInt64 = 'L', ptFloat32 = 'F', ptFloat64 = 'D',
    ptString = 'S', ptRaw = 'R'
  ArrayType* = enum
    paBool = 'b', paInt32 = 'i', paInt64 = 'l', paFloat32 = 'f', paFloat64 = 'd'

  Prop* = object
    ptype*: PropType
    atype*: ArrayType
    isArray*: bool
    compressed*: bool
    uncLen*: int
    i*: int64
    f*: float64
    s*: string
    raw*: seq[byte]

  Node* = ref object
    id*: string
    props*: seq[Prop]
    elems*: seq[Node]
    endOffset*: int
    propsLength*: int

const
  HeadMagic = "Kaydara FBX Binary  \x00\x1A\x00"
  FootId: array[16, byte] = [0xFA'u8, 0xBC, 0xAB, 0x09, 0xD0, 0xC8, 0xD4, 0x66,
                             0xB1, 0x76, 0xFB, 0x83, 0x1C, 0xF7, 0x26, 0x7E]
  TailId: array[16, byte] = [0xF8'u8, 0x5A, 0x8C, 0x6A, 0xDE, 0xF5, 0xD9, 0x7E,
                             0xEC, 0xE9, 0x0C, 0xE3, 0x75, 0x8F, 0x29, 0x0B]
  BlockSentinelLen = 13

proc adler32(data: openArray[byte]): uint32 =
  var a: uint32 = 1
  var b: uint32 = 0
  for c in data:
    a = (a + uint32(c)) mod 65521'u32
    b = (b + a) mod 65521'u32
  result = (b shl 16) or a

const
  LenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51,
             59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
              4, 5, 5, 5, 5, 0]
  DistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
              513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385,
              24577]
  DistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9,
               10, 10, 11, 11, 12, 12, 13, 13]

type BitWriter = object
  buf: seq[byte]
  acc: uint32
  nbits: int

proc bwPut(w: var BitWriter, value: uint32, n: int) =
  ## deflate packs bits least-significant first.
  w.acc = w.acc or ((value and ((1'u32 shl n) - 1'u32)) shl w.nbits)
  w.nbits += n
  while w.nbits >= 8:
    w.buf.add byte(w.acc and 0xFF'u32)
    w.acc = w.acc shr 8
    w.nbits -= 8

proc bwCode(w: var BitWriter, code, n: int) =
  ## Huffman codes travel most-significant bit first, so reverse them.
  var v = 0
  for k in 0..<n:
    v = (v shl 1) or ((code shr k) and 1)
  w.bwPut(uint32(v), n)

proc bwLit(w: var BitWriter, lit: int) =
  if lit < 144: w.bwCode(0x30 + lit, 8)
  elif lit < 256: w.bwCode(0x190 + lit - 144, 9)
  elif lit < 280: w.bwCode(lit - 256, 7)
  else: w.bwCode(0xC0 + lit - 280, 8)

proc bwAlignByte(w: var BitWriter) =
  if w.nbits > 0:
    w.buf.add byte(w.acc and 0xFF'u32)
    w.acc = 0
    w.nbits = 0

proc compress*(data: seq[byte]): seq[byte] =
  ## zlib stream: one fixed-Huffman deflate block (LZ77 greedy matcher) plus
  ## the adler32 checksum.  Produces the same framing as `zlib.compress`, so
  ## Blender and Unity both read it back unchanged.
  result = @[0x78'u8, 0x9C'u8]
  var w = BitWriter(buf: @[], acc: 0, nbits: 0)
  const HashBits = 15
  const HashSize = 1 shl HashBits
  const MaxChain = 48
  const Window = 32768
  let n = data.len
  var head = newSeq[int32](HashSize)
  var prev = newSeq[int32](if n > 0: n else: 1)
  for i in 0 ..< head.len: head[i] = -1
  for i in 0 ..< prev.len: prev[i] = -1

  proc hashAt(p: int): uint32 =
    (uint32(data[p]) shl 10 xor uint32(data[p + 1]) shl 5 xor uint32(data[p + 2])) and
      uint32(HashSize - 1)

  w.bwPut(1'u32, 1)          # BFINAL
  w.bwPut(1'u32, 2)          # BTYPE = 01, fixed Huffman
  var i = 0
  while i < n:
    var bestLen = 0
    var bestDist = 0
    if i + 3 <= n:
      let h = int(hashAt(i))
      var cand = head[h]
      var chain = 0
      let maxLen = min(258, n - i)
      while cand >= 0 and chain < MaxChain:
        let dist = i - int(cand)
        if dist <= 0 or dist > Window: break
        if data[int(cand) + bestLen] == data[i + bestLen]:
          var l = 0
          while l < maxLen and data[int(cand) + l] == data[i + l]:
            inc l
          if l > bestLen:
            bestLen = l
            bestDist = dist
            if l >= maxLen: break
        cand = prev[int(cand)]
        inc chain
      # register this position
      prev[i] = head[h]
      head[h] = int32(i)
    if bestLen >= 3:
      var lc = 0
      while lc < 28 and LenBase[lc + 1] <= bestLen: inc lc
      w.bwLit(257 + lc)
      if LenExtra[lc] > 0:
        w.bwPut(uint32(bestLen - LenBase[lc]), LenExtra[lc])
      var dc = 29
      while dc > 0 and DistBase[dc] > bestDist: dec dc
      w.bwCode(dc, 5)
      if DistExtra[dc] > 0:
        w.bwPut(uint32(bestDist - DistBase[dc]), DistExtra[dc])
      # keep the hash chain dense across the match
      for k in 1 ..< bestLen:
        if i + k + 3 <= n:
          let h2 = int(hashAt(i + k))
          prev[i + k] = head[h2]
          head[h2] = int32(i + k)
      i += bestLen
    else:
      w.bwLit(int(data[i]))
      inc i
  w.bwLit(256)             # end of block
  w.bwAlignByte()
  for b in w.buf: result.add b
  let bound = adler32(data)
  result.add byte((bound shr 24) and 0xFF'u32)
  result.add byte((bound shr 16) and 0xFF'u32)
  result.add byte((bound shr 8) and 0xFF'u32)
  result.add byte(bound and 0xFF'u32)

proc newNode*(id: string): Node =
  new(result)
  result.id = id

proc elem*(parent: Node, id: string): Node =
  let n = newNode(id)
  parent.elems.add(n)
  n

proc addBool*(n: Node, v: bool) =
  n.props.add(Prop(ptype: ptBool, i: (if v: 1'i64 else: 0'i64)))

proc addChar*(n: Node, v: char) =
  n.props.add(Prop(ptype: ptChar, i: int64(ord(v))))

proc addInt32*(n: Node, v: int32) =
  n.props.add(Prop(ptype: ptInt32, i: int64(v)))

proc addInt64*(n: Node, v: int64) =
  n.props.add(Prop(ptype: ptInt64, i: v))

proc addFloat32*(n: Node, v: float32) =
  n.props.add(Prop(ptype: ptFloat32, f: float64(v)))

proc addFloat64*(n: Node, v: float64) =
  n.props.add(Prop(ptype: ptFloat64, f: v))

proc addString*(n: Node, v: string) =
  n.props.add(Prop(ptype: ptString, s: v))

proc addRaw*(n: Node, v: seq[byte]) =
  n.props.add(Prop(ptype: ptRaw, raw: v))

proc addInt32Array*(n: Node, values: openArray[int32]) =
  var raw = newSeq[byte](values.len * 4)
  for i, v in values:
    let u = cast[uint32](v)
    raw[i * 4] = byte(u and 0xFF'u32)
    raw[i * 4 + 1] = byte((u shr 8) and 0xFF'u32)
    raw[i * 4 + 2] = byte((u shr 16) and 0xFF'u32)
    raw[i * 4 + 3] = byte((u shr 24) and 0xFF'u32)
  n.props.add(Prop(ptype: ptInt32, atype: paInt32, isArray: true, raw: raw))

proc addInt64Array*(n: Node, values: openArray[int64]) =
  var raw = newSeq[byte](values.len * 8)
  for i, v in values:
    let u = cast[uint64](v)
    for k in 0..7:
      raw[i * 8 + k] = byte((u shr (8 * k)) and 0xFF'u64)
  n.props.add(Prop(ptype: ptInt64, atype: paInt64, isArray: true, raw: raw))

proc addFloat64Array*(n: Node, values: openArray[float64]) =
  var raw = newSeq[byte](values.len * 8)
  for i, v in values:
    let u = cast[uint64](v)
    for k in 0..7:
      raw[i * 8 + k] = byte((u shr (8 * k)) and 0xFF'u64)
  n.props.add(Prop(ptype: ptFloat64, atype: paFloat64, isArray: true, raw: raw))

proc addFloat32Array*(n: Node, values: openArray[float32]) =
  var raw = newSeq[byte](values.len * 4)
  for i, v in values:
    let u = cast[uint32](v)
    for k in 0..3:
      raw[i * 4 + k] = byte((u shr (8 * k)) and 0xFF'u32)
  n.props.add(Prop(ptype: ptFloat32, atype: paFloat32, isArray: true, raw: raw))

proc propSize(p: Prop): int =
  ## Size of the property payload, excluding the leading type byte.
  if p.isArray: return 12 + p.raw.len
  case p.ptype
  of ptBool, ptChar, ptInt8: 1
  of ptInt16: 2
  of ptInt32, ptFloat32: 4
  of ptInt64, ptFloat64: 8
  of ptString: 4 + p.s.len
  of ptRaw: 4 + p.raw.len

proc propCode(p: Prop): char =
  if p.isArray: char(ord(p.atype)) else: char(ord(p.ptype))

proc calcOffsets(n: Node, offset: int, isLast: bool): int =
  var off = offset + 12 + 1 + n.id.len
  var plen = 0
  for p in n.props:
    plen += 1 + p.propSize
  n.propsLength = plen
  off += plen
  if n.elems.len > 0:
    let lastIdx = n.elems.len - 1
    for i, e in n.elems:
      off = e.calcOffsets(off, i == lastIdx)
    off += BlockSentinelLen
  elif (n.props.len == 0 and not isLast):
    off += BlockSentinelLen
  n.endOffset = off
  off

proc writeProp(s: var string, p: Prop) =
  s.add(p.propCode)
  template put32(x: uint32) =
    for k in 0..3: s.add(char(int((x shr (8'u32 * uint32(k))) and 0xFF'u32)))
  template put64(x: uint64) =
    for k in 0..7: s.add(char(int((x shr (8'u64 * uint64(k))) and 0xFF'u64)))
  if p.isArray:
    put32(uint32(p.uncLen))
    put32(if p.compressed: 1'u32 else: 0'u32)
    put32(uint32(p.raw.len))
    for b in p.raw: s.add(char(b))
  else:
    case p.ptype
    of ptBool, ptChar, ptInt8: s.add(char(int(p.i) and 0xFF))
    of ptInt16:
      put32(cast[uint32](cast[int32](p.i)) and 0xFFFF'u32)
    of ptInt32: put32(cast[uint32](cast[int32](p.i)))
    of ptFloat32: put32(cast[uint32](cast[float32](p.f)))
    of ptInt64: put64(cast[uint64](p.i))
    of ptFloat64: put64(cast[uint64](p.f))
    of ptString:
      put32(uint32(p.s.len))
      s.add(p.s)
    of ptRaw:
      put32(uint32(p.raw.len))
      for b in p.raw: s.add(char(b))

proc writeNode(n: Node, s: var string, isLast: bool) =
  s.add(char(n.endOffset and 0xFF))
  s.add(char((n.endOffset shr 8) and 0xFF))
  s.add(char((n.endOffset shr 16) and 0xFF))
  s.add(char((n.endOffset shr 24) and 0xFF))
  s.add(char(n.props.len and 0xFF))
  s.add(char((n.props.len shr 8) and 0xFF))
  s.add(char((n.props.len shr 16) and 0xFF))
  s.add(char((n.props.len shr 24) and 0xFF))
  s.add(char(n.propsLength and 0xFF))
  s.add(char((n.propsLength shr 8) and 0xFF))
  s.add(char((n.propsLength shr 16) and 0xFF))
  s.add(char((n.propsLength shr 24) and 0xFF))
  s.add(char(n.id.len and 0xFF))
  s.add(n.id)
  for p in n.props:
    writeProp(s, p)
  if n.elems.len > 0:
    let lastIdx = n.elems.len - 1
    for i, e in n.elems:
      writeNode(e, s, i == lastIdx)
    for _ in 0..<BlockSentinelLen: s.add('\0')
  elif n.props.len == 0 and not isLast:
    for _ in 0..<BlockSentinelLen: s.add('\0')

proc writeChildren(root: Node, s: var string) =
  if root.elems.len == 0: return
  let lastIdx = root.elems.len - 1
  for i, e in root.elems:
    writeNode(e, s, i == lastIdx)
  for _ in 0..<BlockSentinelLen: s.add('\0')

proc calcOffsetsChildren(n: Node, offset: int, isLast: bool): int =
  var off = offset
  if n.elems.len > 0:
    let lastIdx = n.elems.len - 1
    for i, e in n.elems:
      off = e.calcOffsets(off, i == lastIdx)
    off += BlockSentinelLen
  elif (n.props.len == 0 and not isLast):
    off += BlockSentinelLen
  off

proc finalizeProps(n: Node) =
  ## Deflate array payloads that exceed 128 bytes and record their on-disk
  ## length, so that `propSize` stays accurate once offsets are calculated.
  ## Like Blender, only mark a payload as compressed when that actually makes
  ## it smaller - otherwise the reader would inflate for nothing.
  for i in 0 ..< n.props.len:
    if not n.props[i].isArray: continue
    let itemSize = (case n.props[i].atype
                    of paBool: 1
                    of paInt32, paFloat32: 4
                    else: 8)
    n.props[i].uncLen = n.props[i].raw.len div itemSize
    if n.props[i].raw.len > 128:
      let packed = compress(n.props[i].raw)
      if packed.len < n.props[i].raw.len:
        n.props[i].raw = packed
        n.props[i].compressed = true
  for e in n.elems: e.finalizeProps()

proc encode*(root: Node, version = 7400'u32): string =
  ## Serialise the element tree into a binary FBX byte string.
  root.finalizeProps()
  discard root.calcOffsetsChildren(len(HeadMagic) + 4, false)
  var s = HeadMagic
  s.add(char(version and 0xFF'u32))
  s.add(char((version shr 8) and 0xFF'u32))
  s.add(char((version shr 16) and 0xFF'u32))
  s.add(char((version shr 24) and 0xFF'u32))
  root.writeChildren(s)
  for b in FootId: s.add(char(b))
  for _ in 0..<4: s.add('\0')
  var pad = ((s.len + 15) and not 15) - s.len
  if pad == 0: pad = 16
  for _ in 0..<pad: s.add('\0')
  s.add(char(version and 0xFF'u32))
  s.add(char((version shr 8) and 0xFF'u32))
  s.add(char((version shr 16) and 0xFF'u32))
  s.add(char((version shr 24) and 0xFF'u32))
  for _ in 0..<120: s.add('\0')
  for b in TailId: s.add(char(b))
  result = s
