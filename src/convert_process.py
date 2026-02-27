import os

from jinja2 import TemplateRuntimeError
os.environ['GLOG_minloglevel'] = '3'
import bpy
import sys
import shutil
import pathlib
import re
sys.path.append(os.path.dirname(__file__))
import utils

def convert_to_fbx(vrm_path: str, fbx_path) -> None:
    app_data = os.path.join(os.environ.get('APPDATA'), "CatelliteV2F")
    addon_path = os.path.join(app_data, "addons")
    if not os.path.isdir(app_data):
        os.mkdir(app_data)
    if not os.path.isdir(addon_path):
        os.mkdir(addon_path)

    # 初期化
    bpy.ops.wm.read_factory_settings(use_empty=False)
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)

    # アドオンのダウンロードと展開、初期化
    utils.get_addons(addon_path)
    utils.unpack_addons(addon_path)
    utils.initialize_addon(addon_path)    

    # VRMファイルのインポート
    bpy.ops.import_scene.vrm(
        filepath=vrm_path,
        use_addon_preferences=True,
        extract_textures_into_folder=False,
        make_new_texture_folder=True,
        set_shading_type_to_material_on_import=True,
        set_view_transform_to_standard_on_import=True,
        set_armature_display_to_wire=True,
        set_armature_display_to_show_in_front=True,
        set_armature_bone_shape_to_default=True,
        enable_mtoon_outline_preview=True
    )

    # VRM最適化
    bpy.context.scene.keep_end_bones = True
    bpy.context.scene.keep_upper_chest = False
    bpy.context.scene.join_meshes = False

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.cats_armature.fix_armature_warning('EXEC_DEFAULT')

    # Visemeの作成
    bpy.context.scene.mesh_name_viseme = 'Face'
    bpy.context.scene.mouth_a = 'Fcl_MTH_A'
    bpy.context.scene.mouth_o = 'Fcl_MTH_O'
    bpy.context.scene.mouth_ch = 'Fcl_MTH_I'
    bpy.ops.cats_viseme.create('EXEC_DEFAULT')

    # Eyeトラッキング作成
    bpy.context.scene.mesh_name_eye = 'Face'
    bpy.context.scene.eye_left = 'Eye_L'
    bpy.context.scene.eye_right = 'Eye_R'
    bpy.context.scene.disable_eye_blinking = True
    bpy.ops.cats_eyes.create_eye_tracking('EXEC_DEFAULT')
    bpy.ops.cats_eyes.av3_orient_eye_bones('EXEC_DEFAULT')

    # ボーン割り当て
    armature = [obj for obj in bpy.data.objects if obj.type == 'ARMATURE'][0]
    bpy.ops.vrm.assign_vrm0_humanoid_human_bones_automatically('EXEC_DEFAULT', armature_object_name=armature.name)

    # Tポーズ適用
    bpy.ops.vrm.make_estimated_humanoid_t_pose('EXEC_DEFAULT', armature_object_name=armature.name)
    try:
        bpy.context.view_layer.objects.active = armature
        bpy.ops.object.mode_set(mode='POSE')
        bpy.ops.pose.select_all(action='SELECT')
        bpy.ops.cats_manual.pose_to_rest('EXEC_DEFAULT')
        bpy.ops.object.mode_set(mode='OBJECT')
    except Exception as e:
        print(f"Tポーズの適用に失敗: {e}")

    # ボーン編集
    bpy.ops.object.mode_set(mode='EDIT')
    tail = armature.data.edit_bones['Spine'].tail[1]
    armature.data.edit_bones['Spine'].head[1] = tail
    armature.data.edit_bones['Chest'].tail[1] = tail
    armature.data.edit_bones['Chest'].head[1] = 0
    armature.data.edit_bones['Neck'].tail[1] = 0
    armature.data.edit_bones['Neck'].head[1] = 0
    bpy.ops.object.mode_set(mode='OBJECT')

    # FBXエクスポート
    bpy.ops.export_scene.fbx(
        filepath=fbx_path,
        use_selection=False,
        path_mode='COPY',
        embed_textures=True,
        add_leaf_bones=False,
        bake_anim=False,
        object_types={'ARMATURE', 'MESH'},
        use_mesh_modifiers=False
    )

if __name__ == "__main__":
    convert_to_fbx(sys.argv[1], sys.argv[2])