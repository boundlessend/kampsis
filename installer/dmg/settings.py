# настройки dmgbuild: окно Finder с приложением, ярлыком Applications и инструкцией
# пути приходят из scripts/build-dmg.sh через -D app=... -D assets=...
from pathlib import Path

app = Path(defines["app"])
assets = Path(defines["assets"])

format = "UDZO"
filesystem = "HFS+"
files = [str(app), (str(assets / "guide.html"), "Install.html")]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
background = str(assets / "background.tiff")

window_rect = ((240, 180), (640, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 96
text_size = 13
label_pos = "bottom"
hide_extensions = ["Install.html"]
icon_locations = {
    "Kampsis.app": (170, 210),
    "Applications": (470, 210),
    "Install.html": (320, 310),
}
