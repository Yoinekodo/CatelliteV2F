import flet as ft
import asyncio
import os
import sys
from dataclasses import dataclass
sys.path.append(os.path.dirname(__file__))
from convert_process import convert_to_fbx
from trial_manager import trial_set, get_expired

@ft.observable
@dataclass
class GlobalState:
    vrm_path: str = ""
    fbx_path: str = ""

    def set_vrm_path(self, vrm_path):
        self.vrm_path = vrm_path
    
    def set_fbx_path(self, fbx_path):
        self.fbx_path = fbx_path

GlobalContext = ft.create_context(GlobalState())

@ft.component
def FilePicker():
    global_context = ft.use_context(GlobalContext)

    async def set_vrm_path(e):
        files = await ft.FilePicker().pick_files(dialog_title="変換するVRM", allowed_extensions=["vrm"])
        if files:
            file = files[0]
            global_context.set_vrm_path(file.path)
            await asyncio.sleep(0.1)
    
    async def set_fbx_path(e):
        files = await ft.FilePicker().save_file(dialog_title="保存FBX名", allowed_extensions=["fbx"])
        if files:
            if not ".fbx" in files:
                files = files + ".fbx"
            global_context.set_fbx_path(files)
            await asyncio.sleep(0.1)
    
    return ft.Column([
        ft.Button("変換するVRMを選択", icon=ft.Icons.FILE_OPEN, on_click=set_vrm_path),
        ft.Row([ft.Text("VRMファイル:"), ft.Text(global_context.vrm_path)]),
        ft.Divider(),
        ft.Button("保存後のFBXの名前を指定", icon=ft.Icons.SAVE, on_click=set_fbx_path),
        ft.Row([ft.Text("FBXファイル名:"), ft.Text(global_context.fbx_path)])
    ])
        
@ft.component
def App():
    page = ft.context.page
    progress_ring, set_progress_ring = ft.use_state(False)
    status_icon, set_status_icon = ft.use_state("idle")
    status_text, set_status_text = ft.use_state("")
    status_color, set_status_color = ft.use_state("")
    run_button_disable, set_run_button_disable = ft.use_state(False)
    global_context = ft.use_context(GlobalContext)

    unlimit, set_unlimit = ft.use_state(True)
    expired, delta = get_expired("Software\\CatelliteV2F")

    if expired == "unlimit":
        set_unlimit(True)
    
    def expired_process():
        set_run_button_disable(True)

        async def close(e):
            await page.window.close()
        
        page.show_dialog(
            ft.AlertDialog(
                title=ft.Text("期限切れ"),
                content=ft.Text("トライアル期間が終了しています。\nツールを使い続ける場合は[宵猫堂]より\n制限解除装置を購入いただくか\nCatelliteActivatorをご購入ください"),
                actions=[
                    ft.TextButton(
                        "閉じる",
                        on_click=close,
                        icon=ft.Icons.CLOSE
                    )
                ]
            )
        )
    
    if int(delta) <= 0:
        expired_process()

    async def run_convert(e):
        set_run_button_disable(True)
        set_progress_ring(True)
        set_status_text("処理開始")
        set_status_icon("progress")
        set_status_color("blue")
        await asyncio.sleep(0.1)
        if global_context.vrm_path == "" or global_context.fbx_path == "":
            set_run_button_disable(False)
            set_progress_ring(False)
            set_status_text("VRMファイルのパス\nもしくはFBXの保存名\n指定されていないため\n処理を開始できません。")
            set_status_icon("error")
            set_status_color("red")
            await asyncio.sleep(0.1)
        else:
            set_status_text("変換中...")
            await asyncio.sleep(0.1)
            convert_to_fbx(global_context.vrm_path, global_context.fbx_path)
            set_run_button_disable(False)
            set_progress_ring(False)
            set_status_text(f"処理完了\n{global_context.fbx_path}へ\n保存しました。")
            set_status_icon("success")
            set_status_color("green")
            await asyncio.sleep(0.1)

    return ft.Column([
        FilePicker(),
        ft.Divider(),
        ft.Button("変換開始", icon=ft.Icons.REFRESH, on_click=run_convert, disabled=run_button_disable),
        ft.Row([
            ft.Stack([
                ft.ProgressRing(visible=progress_ring),
                ft.Icon(icon=ft.Icons.CHECK_CIRCLE if status_icon == "success" else ft.Icons.CANCEL, color=ft.Colors.GREEN if status_icon == "success" else ft.Colors.RED, visible=False if status_icon == "progress" or status_icon == "idle" else True)
            ]),
            ft.Text(status_text, color=status_color if status_icon != "success" else "green")
        ]),
        ft.Column([
            ft.Text(f"有効期限 : {expired} まで", visible=unlimit),
            ft.Text(f"残り : {delta} 日", visible=unlimit)
        ], alignment=ft.MainAxisAlignment.END)
    ])



def main(page: ft.Page):
    trial_set("Software\\CatelliteV2F")

    page.title = "Catellite V2F"
    page.window.width = 500
    page.window.height = 400
    page.window.resizable = False
    page.window.maximizable = False

    icon_path = os.path.join(os.path.dirname(__file__), "icon.ico")
    page.window.icon = icon_path

    page.render(App)


ft.run(main)
