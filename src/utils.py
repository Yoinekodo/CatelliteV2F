import sys
import os
from pathlib import Path
import importlib
import bpy
import requests
import shutil

def initialize_addon(addon_dir: str) -> None:
    addon_dir_path: Path = Path(addon_dir)
    if not addon_dir or not addon_dir_path.exists():
        sys.exit(f"addon dir not found: '{addon_dir}'")
    
    if addon_dir not in sys.path:
        sys.path.append(addon_dir)

    loaded_modules = set()
    modules = bpy.utils.modules_from_path(addon_dir, loaded_modules)

    for module in modules:
        addon_name = module.__name__
        importlib.reload(module)

        if addon_name not in bpy.context.preferences.addons:
            bpy.ops.preferences.addon_enable(module=addon_name)

def get_addons(addon_dir: str):
    if not os.path.isdir(os.path.join(addon_dir, "VRM_Addon")):
        vrm_format = 'https://github.com/saturday06/VRM-Addon-for-Blender/releases/download/v3.19.4/VRM_Addon_for_Blender-Extension-3_19_4.zip'
        vrm_addon_name = 'VRM_Addon.zip'
        vrmData = requests.get(vrm_format).content
        with open(os.path.join(addon_dir,vrm_addon_name), 'wb') as f:
            f.write(vrmData)
    if not os.path.isdir(os.path.join(addon_dir, "Cats-Blender-Plugin-Blender-5x")):
        cats_blender = 'https://github.com/teamneoneko/Cats-Blender-Plugin/releases/download/5.0.2.3/Cats-Blender-Plugin-Unofficial5.0.2.3.zip'
        cats_blender_name = 'Cats_Blender.zip'
        catsData = requests.get(cats_blender).content
        with open(os.path.join(addon_dir,cats_blender_name), 'wb') as f:
            f.write(catsData)

def unpack_addons(addon_dir: str):
    if os.path.isfile(os.path.join(addon_dir, "VRM_Addon.zip")):
        shutil.unpack_archive(os.path.join(addon_dir, "VRM_Addon.zip"), os.path.join(addon_dir, "VRM_Addon"))
        os.remove(os.path.join(addon_dir, "VRM_Addon.zip"))
    if os.path.isfile(os.path.join(addon_dir, "Cats_Blender.zip")):
        shutil.unpack_archive(os.path.join(addon_dir, "Cats_Blender.zip"), os.path.join(addon_dir, "Cats_Blender"))
        shutil.move(os.path.join(addon_dir, "Cats_Blender/Cats-Blender-Plugin-Blender-5x"), addon_dir)

        shutil.rmtree(os.path.join(addon_dir, "Cats_Blender"))
        os.remove(os.path.join(addon_dir, "Cats_Blender.zip"))

        line_number = 68
        new_line = '        with open(translation_file, \'r\', encoding=\'utf-8\') as file:'

        with open(os.path.join(addon_dir, "Cats-Blender-Plugin-Blender-5x/tools/translations.py"), 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        if line_number <= len(lines):
            lines[line_number - 1] = new_line
            with open(os.path.join(addon_dir, "Cats-Blender-Plugin-Blender-5x/tools/translations.py"), 'w', encoding='utf-8') as f:
                f.writelines(lines)
