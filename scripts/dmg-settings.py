# dmgbuild settings for the Eyes Driven 2me installer disk image.
# Invoked by scripts/make-dmg.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=... -D background=... "Eyes Driven 2me" out.dmg
import os

app = defines["app"]                # path to EyesDriven2me.app
background = defines["background"]  # multi-resolution TIFF (1x + 2x)
app_name = os.path.basename(app)

format = "UDZO"                     # zlib-compressed, read-only
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")  # volume icon

# Finder window (keep in sync with scripts/render-dmg-background.swift: 660x400).
background = background
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (180, 190),
    "Applications": (480, 190),
}
hide_extensions = [app_name]
