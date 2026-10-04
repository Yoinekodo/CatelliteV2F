## Small math library (3D vectors, 4x4 matrices, quaternions) used by the
## VRM -> FBX conversion pipeline.  Matrices are stored row major in
## `Mat4`, and `*` composes matrices the same way Blender's mathutils does
## (`a * b` applies `b` first, then `a`).
import std/math

type
  Vec3* = array[3, float64]
  Vec4* = array[4, float64]
  Mat3* = array[3, array[3, float64]]
  Mat4* = array[4, array[4, float64]]
  Quat* = array[4, float64]   ## x, y, z, w

const
  IdMat4*: Mat4 = [[1.0, 0.0, 0.0, 0.0],
                   [0.0, 1.0, 0.0, 0.0],
                   [0.0, 0.0, 1.0, 0.0],
                   [0.0, 0.0, 0.0, 1.0]]

proc `+`*(a, b: Vec3): Vec3 = [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
proc `-`*(a, b: Vec3): Vec3 = [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
proc `*`*(a: Vec3, s: float64): Vec3 = [a[0] * s, a[1] * s, a[2] * s]
proc `*`*(s: float64, a: Vec3): Vec3 = a * s
proc `*`*(a, b: Vec3): float64 = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
proc `dot`(a, b: Vec3): float64 = a * b
proc cross*(a, b: Vec3): Vec3 = [a[1] * b[2] - a[2] * b[1],
                                  a[2] * b[0] - a[0] * b[2],
                                  a[0] * b[1] - a[1] * b[0]]
proc len*(a: Vec3): float64 = sqrt(a * a)
proc lenSq*(a: Vec3): float64 = a * a
proc norm*(a: Vec3): Vec3 =
  let l = a.len
  if l < 1e-12: [0.0, 0.0, 0.0] else: a * (1.0 / l)
proc normalized*(a: Vec3): Vec3 = a.norm
proc floor3*(a: Vec3): Vec3 = [floor(a[0]), floor(a[1]), floor(a[2])]

proc mat4Mul*(a, b: Mat4): Mat4 =
  result = IdMat4
  for i in 0..3:
    for j in 0..3:
      var s = 0.0
      for k in 0..3:
        s += a[i][k] * b[k][j]
      result[i][j] = s

proc `*`*(a, b: Mat4): Mat4 = mat4Mul(a, b)

proc `*`*(a: Mat4, v: Vec4): Vec4 =
  result = [0.0, 0.0, 0.0, 0.0]
  for i in 0..3:
    var s = 0.0
    for k in 0..3:
      s += a[i][k] * v[k]
    result[i] = s

proc `*`*(a: Mat4, v: Vec3): Vec3 =
  let r = a * [v[0], v[1], v[2], 1.0]
  [r[0], r[1], r[2]]

proc transposed*(a: Mat4): Mat4 =
  for i in 0..3:
    for j in 0..3:
      result[i][j] = a[j][i]

proc translation*(t: Vec3): Mat4 =
  result = IdMat4
  result[0][3] = t[0]
  result[1][3] = t[1]
  result[2][3] = t[2]

proc scaling*(s: Vec3): Mat4 =
  result = IdMat4
  result[0][0] = s[0]
  result[1][1] = s[1]
  result[2][2] = s[2]

proc getTranslation*(a: Mat4): Vec3 = [a[0][3], a[1][3], a[2][3]]

proc col*(a: Mat4, c: int): Vec3 = [a[0][c], a[1][c], a[2][c]]

proc setCol*(a: var Mat4, c: int, v: Vec3) =
  a[0][c] = v[0]
  a[1][c] = v[1]
  a[2][c] = v[2]

proc boneBasis*(dir: Vec3): Mat4 =
  ## Blender's `vec_roll_to_mat3(dir, 0)`, i.e. the matrix `BKE_armature_mat_from_bone`
  ## builds for a bone whose roll is zero (`source/blender/blenkernel/intern/armature.cc`,
  ## `vec_roll_to_mat3_normalized`).  It is the unique roll-zero rotation mapping
  ## +Y onto `dir`; unlike a Gram-Schmidt frame against a world axis it depends on
  ## nothing but the bone direction, which is what Blender guarantees.
  ##
  ## With `(x, y, z)` the components of the normalised direction and `theta = 1 + y`
  ## the matrix is
  ##   `( 1 - x^2/t   x   -xz/t )`
  ##   `(     -x      y     -z  )`
  ##   `(  -xz/t       z   1-z^2/t )`
  ## `theta` divides by `1 + y`, which vanishes for a bone pointing exactly along -Y,
  ## so that case uses Blender's mirrored-XZ fallback instead.
  const SafeThreshold = 6.1e-3      # theta above this is precise enough
  const CriticalSquared = 2.5e-4 * 2.5e-4
  let n = dir.norm
  let x = n[0]
  let y = n[1]
  let z = n[2]
  var theta = 1.0 + y
  let thetaAlt = x * x + z * z     # squared distance from the bone axis
  result = IdMat4
  if theta > SafeThreshold or thetaAlt > CriticalSquared:
    if theta <= SafeThreshold:
      # Near -Y, 1/(1+y) is numerically hopeless; rebuild theta from x and z
      # with the second order series expansion of 1 - sqrt(1 - t).
      theta = thetaAlt * 0.5 + thetaAlt * thetaAlt * 0.125
    result.setCol(0, [1.0 - x * x / theta, -x, -x * z / theta])
    result.setCol(1, n)
    result.setCol(2, [-x * z / theta, -z, 1.0 - z * z / theta])
  else:
    # True singularity: Blender keeps the identity and mirrors X and Y.
    result.setCol(0, [-1.0, 0.0, 0.0])
    result.setCol(1, [0.0, -1.0, 0.0])
    result.setCol(2, [0.0, 0.0, 1.0])

proc boneBasisRoll0*(yAxis: Vec3, headPos: Vec3): Mat4 =
  ## Deprecated shim kept so older call sites keep compiling; `headPos` played no
  ## role in Blender's construction.
  boneBasis(yAxis)

proc rotX*(deg: float64): Mat4 =
  let a = deg * PI / 180.0
  let c = cos(a);
  let s = sin(a)
  result = IdMat4
  result[1][1] = c; result[1][2] = -s
  result[2][1] = s; result[2][2] = c

proc rotY*(deg: float64): Mat4 =
  let a = deg * PI / 180.0
  let c = cos(a);
  let s = sin(a)
  result = IdMat4
  result[0][0] = c; result[0][2] = s
  result[2][0] = -s; result[2][2] = c

proc rotZ*(deg: float64): Mat4 =
  let a = deg * PI / 180.0
  let c = cos(a);
  let s = sin(a)
  result = IdMat4
  result[0][0] = c; result[0][1] = -s
  result[1][0] = s; result[1][1] = c

proc det3*(a: Mat4): float64 =
  a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
  a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
  a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])

proc invert*(a: Mat4): Mat4 =
  ## General 4x4 inverse via Gauss-Jordan.
  var m: array[4, array[8, float64]]
  for i in 0..3:
    for j in 0..3:
      m[i][j] = a[i][j]
      m[i][j + 4] = (if i == j: 1.0 else: 0.0)
  for col in 0..3:
    var piv = col
    for r in col + 1..3:
      if abs(m[r][col]) > abs(m[piv][col]): piv = r
    if abs(m[piv][col]) < 1e-14:
      return IdMat4
    if piv != col:
      for j in 0..7:
        swap(m[col][j], m[piv][j])
    let d = m[col][col]
    for j in 0..7:
      m[col][j] /= d
    for r in 0..3:
      if r == col: continue
      let f = m[r][col]
      if f == 0.0: continue
      for j in 0..7:
        m[r][j] -= f * m[col][j]
  for i in 0..3:
    for j in 0..3:
      result[i][j] = m[i][j + 4]

proc invertSafe*(a: Mat4): Mat4 =
  try: result = a.invert
  except ValueError: result = IdMat4

proc quatToMat*(q: Quat): Mat4 =
  ## (x, y, z, w) quaternion -> rotation matrix.
  let x = q[0]
  let y = q[1]
  let z = q[2]
  let w = q[3]
  result = IdMat4
  result[0][0] = 1 - 2 * (y * y + z * z)
  result[0][1] = 2 * (x * y - z * w)
  result[0][2] = 2 * (x * z + y * w)
  result[1][0] = 2 * (x * y + z * w)
  result[1][1] = 1 - 2 * (x * x + z * z)
  result[1][2] = 2 * (y * z - x * w)
  result[2][0] = 2 * (x * z - y * w)
  result[2][1] = 2 * (y * z + x * w)
  result[2][2] = 1 - 2 * (x * x + y * y)

proc matToQuat*(m: Mat4): Quat =
  ## Matrix -> quaternion (Blender compatible branch selection).
  let m00 = m[0][0];
  let m01 = m[0][1];
  let m02 = m[0][2]
  let m10 = m[1][0];
  let m11 = m[1][1];
  let m12 = m[1][2]
  let m20 = m[2][0];
  let m21 = m[2][1];
  let m22 = m[2][2]
  let tr = m00 + m11 + m22
  if tr > 0.0:
    let s = sqrt(tr + 1.0) * 2.0
    result = [(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s]
  elif m00 > m11 and m00 > m22:
    let s = sqrt(1.0 + m00 - m11 - m22) * 2.0
    result = [0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s]
  elif m11 > m22:
    let s = sqrt(1.0 + m11 - m00 - m22) * 2.0
    result = [(m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s]
  else:
    let s = sqrt(1.0 + m22 - m00 - m11) * 2.0
    result = [(m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s]

proc quatMul*(a, b: Quat): Quat =
  ## Hamilton product (a * b).
  let ax = a[0]
  let ay = a[1]
  let az = a[2]
  let aw = a[3]
  let bx = b[0]
  let by = b[1]
  let bz = b[2]
  let bw = b[3]
  result = [aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz]

proc quatRotate*(q: Quat, v: Vec3): Vec3 =
  let m = quatToMat(q)
  [m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
   m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
   m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2]]

proc matToEulerXYZ*(m: Mat4): Vec3 =
  ## Matrix -> Euler angles (degrees) with Blender's 'XYZ' convention, i.e.
  ## `m = Rz * Ry * Rx`.  This is the exact inverse of `eulerXYZToMat`, and it
  ## is what the FBX exporter puts into a bone node's `Lcl Rotation`
  ## (Blender's own exporter calls `Quaternion.to_euler('XYZ')`).
  ##
  ## `Mat4` is column major (`m[column][row]`), so element (row, col) reads
  ## `m[col][row]`.  For `Rz*Ry*Rx` the last row is (-sy, cy*sx, cy*cx), and
  ## (row1,col0) = cy*sz, (row0,col0) = cy*cz, hence
  ##   y = asin(-(row2,col0)),  x = atan2((row2,col1), (row2,col2)),
  ##   z = atan2((row1,col0), (row0,col0))
  let r20 = m[0][2]
  let r21 = m[1][2]
  let r22 = m[2][2]
  let r10 = m[0][1]
  let r00 = m[0][0]
  if abs(r20) < 1.0 - 1e-12:  # not gimbal locked on Y
    let y = arcsin(clamp(-r20, -1.0, 1.0))
    let x = arctan2(r21, r22)
    let z = arctan2(r10, r00)
    result = [x * 180.0 / PI, y * 180.0 / PI, z * 180.0 / PI]
  else:
    # y = +-90 degrees: x and z are no longer separable, fold the rest into x.
    let y = (if r20 < 0.0: PI / 2.0 else: -PI / 2.0)
    let x = arctan2(m[1][1], m[2][1])
    let z = 0.0
    result = [x * 180.0 / PI, y * 180.0 / PI, z * 180.0 / PI]

proc eulerXYZToMat*(e: Vec3): Mat4 =
  result = rotZ(e[2]) * rotY(e[1]) * rotX(e[0])

proc matToEulerZYX*(m: Mat4): Vec3 =
  ## Matrix -> Euler (degrees) for `m = Rx * Ry * Rz` (intrinsic Z, then Y, X).
  let m02 = m[0][2];
  let m12 = m[1][2];
  let m22 = m[2][2]
  let m00 = m[0][0];
  let m01 = m[0][1]
  let m20 = m[2][0];
  let m21 = m[2][1]
  if abs(m02) < 1.0 - 1e-12:
    let y = arcsin(-m02)
    let x = arctan2(m12, m22)
    let z = arctan2(m01, m00)
    result = [x * 180.0 / PI, y * 180.0 / PI, z * 180.0 / PI]
  else:
    let y = -PI / 2.0
    let x = -arctan2(m20, m[1][1])
    let z = 0.0
    result = [x * 180.0 / PI, y * 180.0 / PI, z * 180.0 / PI]

proc decompose*(m: Mat4): tuple[loc: Vec3, quat: Quat, scale: Vec3] =
  ## Split a matrix into translation, rotation and scale, like Blender's
  ## `Matrix.decompose()`.
  result.loc = m.getTranslation
  var rot: Mat4 = IdMat4
  for i in 0..2:
    for j in 0..2:
      rot[i][j] = m[i][j]
  let det = rot[0][0] * (rot[1][1] * rot[2][2] - rot[1][2] * rot[2][1]) -
            rot[0][1] * (rot[1][0] * rot[2][2] - rot[1][2] * rot[2][0]) +
            rot[0][2] * (rot[1][0] * rot[2][1] - rot[1][1] * rot[2][0])
  # Blender folds a mirrored matrix (negative determinant) into the X axis.
  if det < 0.0:
    for i in 0..2: rot[i][0] = -rot[i][0]
  result.scale = [
    sqrt(rot[0][0] * rot[0][0] + rot[1][0] * rot[1][0] + rot[2][0] * rot[2][0]),
    sqrt(rot[0][1] * rot[0][1] + rot[1][1] * rot[1][1] + rot[2][1] * rot[2][1]),
    sqrt(rot[0][2] * rot[0][2] + rot[1][2] * rot[1][2] + rot[2][2] * rot[2][2])]
  for i in 0..2:
    for j in 0..2:
      if result.scale[j] != 0.0: rot[i][j] /= result.scale[j]
  result.quat = rot.matToQuat

proc alignY*(m: Mat4, direction: Vec3): Mat4 =
  ## Rotate `m` (a rotation) so that its local Y axis points along
  ## `direction`, keeping the twist of `m`.  This mirrors what Blender does
  ## when an EditBone's matrix is assigned.
  let yAxis = m * [0.0, 1.0, 0.0, 0.0]
  let yAxis3 = norm([yAxis[0], yAxis[1], yAxis[2]])
  let target = direction.norm
  if yAxis3.len < 1e-9 or target.len < 1e-9:
    return m
  let dot = clamp(yAxis3 * target, -1.0, 1.0)
  if dot > 1.0 - 1e-12:
    return m
  if dot < -1.0 + 1e-12:
    # 180 degree flip: rotate around any perpendicular axis
    var axis = yAxis3.cross([1.0, 0.0, 0.0])
    if axis.len < 1e-6:
      axis = yAxis3.cross([0.0, 0.0, 1.0])
    axis = axis.norm
    let ax = axis
    # Rodrigues rotation by 180 deg
    let c = -1.0
    let s = 0.0
    result = IdMat4
    for i in 0..2:
      for j in 0..2:
        result[i][j] = c * m[i][j] + s * (ax[i] * ax[j]) +
                        (if i == j: 1.0 else: 0.0) - c * (if i == j: 1.0 else: 0.0) +
                        s * 0.0
    # simpler: R = 2*n*n^T - I
    for i in 0..2:
      for j in 0..2:
        result[i][j] = 2.0 * ax[i] * ax[j] - (if i == j: 1.0 else: 0.0)
    return
  let axis = yAxis3.cross(target).norm
  let angle = arccos(dot)
  # Rodrigues
  let (x, y, z) = (axis[0], axis[1], axis[2])
  let c = cos(angle);
  let s = sin(angle);
  let t = 1.0 - c
  let r: Mat3 = [
    [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
    [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
    [t * x * z - s * y, t * y * z + s * x, t * z * z + c]]
  result = IdMat4
  for i in 0..2:
    for j in 0..2:
      var s2 = 0.0
      for k in 0..2:
        s2 += r[i][k] * m[k][j]
      result[i][j] = s2

proc rotationBetween*(a, b: Vec3): Quat =
  ## Shortest arc rotation taking vector `a` onto vector `b`.
  let na = a.norm
  let nb = b.norm
  if na.len < 1e-9 or nb.len < 1e-9:
    return [0.0, 0.0, 0.0, 1.0]
  let d = clamp(na * nb / (na.len * nb.len), -1.0, 1.0)
  if d > 1.0 - 1e-12:
    return [0.0, 0.0, 0.0, 1.0]
  if d < -1.0 + 1e-12:
    var axis = na.cross([1.0, 0.0, 0.0])
    if axis.len < 1e-6:
      axis = na.cross([0.0, 0.0, 1.0])
    axis = axis.norm
    return [axis[0], axis[1], axis[2], 0.0]
  let axis = na.cross(nb)
  result = [axis[0], axis[1], axis[2], 1.0 + d]
  let l = sqrt(result[0] * result[0] + result[1] * result[1] +
                result[2] * result[2] + result[3] * result[3])
  for i in 0..3:
    result[i] /= l
