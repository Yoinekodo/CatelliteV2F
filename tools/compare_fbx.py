## Compare two FBX files' armatures objectively.
##
## Run inside Blender's Text Editor (or `blender -b -P this_file.py -- a.fbx b.fbx`):
##     a_fbx, b_fbx = bpy.path.abspath(sys.argv[-2]), bpy.path.abspath(sys.argv[-1])
##
## It imports both files, then prints a bone-by-bone table of head/tail
## positions plus the roll, so a visual guess can be replaced by numbers.

import bpy
import sys
from mathutils import Vector


def purge():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.actions):
        for d in list(coll):
            coll.remove(d)


def load(path):
    purge()
    bpy.ops.import_scene.fbx(filepath=path)
    arms = [o for o in bpy.data.objects if o.type == 'ARMATURE']
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    info = {}
    for ob in bpy.data.objects:
        info[ob.name] = (
            tuple(round(v, 6) for v in ob.location),
            tuple(round(v, 6) for v in ob.rotation_euler),
            tuple(round(v, 6) for v in ob.scale),
        )
    bones = {}
    if arms:
        for b in arms[0].data.bones:
            bones[b.name] = (tuple(b.head_local), tuple(b.tail_local), b.roll)
    return info, bones, arms, meshes


def main(a_path, b_path):
    ia, ba, arma, mea = load(a_path)
    ib, bb, armb, meb = load(b_path)

    print('\n=== object transforms ===')
    for n in sorted(set(ia) | set(ib)):
        if ia.get(n) != ib.get(n):
            print('  DIFF %-26s A=%s  B=%s' % (n, ia.get(n), ib.get(n)))
    print('  (only differences are listed; A=%s  B=%s)'
          % (a_path, b_path))

    print('\n=== bone count ===')
    print('  A=%d  B=%d  names equal=%s'
          % (len(ba), len(bb), set(ba) == set(bb)))

    print('\n=== bones: head / tail / roll (differences only) ===')
    worst_h = worst_t = worst_r = 0.0
    rows = []
    for n in sorted(set(ba) & set(bb)):
        ha, ta, ra = ba[n]
        hb, tb, rb = bb[n]
        dh = max(abs(x - y) for x, y in zip(ha, hb))
        dt = max(abs(x - y) for x, y in zip(ta, tb))
        dr = abs(ra - rb)
        worst_h = max(worst_h, dh)
        worst_t = max(worst_t, dt)
        worst_r = max(worst_r, dr)
        if dh > 1e-5 or dt > 1e-5:
            rows.append((n, dh, dt))
    print('  max |head delta| = %.6f m' % worst_h)
    print('  max |tail delta| = %.6f m' % worst_t)
    print('  max |roll delta| = %.4f deg' % worst_r)
    print('  bones with head/tail moved: %d' % len(rows))
    for n, dh, dt in rows[:20]:
        print('     %-26s head %.6f  tail %.6f' % (n, dh, dt))

    print('\n=== roll differences (visual bone-axis difference) ===')
    rdiff = sorted(((abs(ba[n][2] - bb[n][2]), n)
                    for n in set(ba) & set(bb)), reverse=True)
    big = [x for x in rdiff if x[0] > 0.5]
    print('  bones with |roll delta| > 0.5 deg: %d of %d'
          % (len(big), len(rdiff)))
    for d, n in big[:25]:
        print('     %-26s A=%.3f  B=%.3f' % (n, ba[n][2], bb[n][2]))

    print('\n=== mesh vertices ===')
    for x, y in zip(sorted(mea, key=lambda o: o.name),
                    sorted(meb, key=lambda o: o.name)):
        va = sorted(tuple(round(c, 5) for c in v.co) for v in x.data.vertices)
        vb = sorted(tuple(round(c, 5) for c in v.co) for v in y.data.vertices)
        same = va == vb
        print('  %-26s verts=%-6d identical point set=%s'
              % (x.name, len(va), same))
        if not same and len(va) == len(vb):
            d = max(max(abs(p[i] - q[i]) for i in range(3))
                    for p, q in zip(va, vb))
            print('     max deviation %.6f m' % d)


args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
if len(args) >= 2:
    main(args[0], args[1])
else:
    print('edit the two paths below and press Run Script')
    main(bpy.path.abspath(r'G:\Yoinekodo\Catellite\CatelliteV2F_old\宵猫ルナ.fbx'),
         bpy.path.abspath(r'C:\Users\stell\AppData\Local\Temp\opencode\v2f\fbmtest\luna.fbx'))