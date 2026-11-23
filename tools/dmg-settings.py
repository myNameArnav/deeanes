# dmgbuild settings: small window, app on the left, Applications on the right.
# Used by dist.sh as: uvx dmgbuild -s tools/dmg-settings.py -D app=... Deeanes out.dmg
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821
format = "UDZO"
compression_level = 9
filesystem = "HFS+"

window_rect = ((200, 200), (540, 320))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (140, 130),
    "Applications": (400, 130),
}
