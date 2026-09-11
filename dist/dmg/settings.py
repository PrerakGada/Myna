# dist/dmg/settings.py — dmgbuild layout for Myna's disk image.
#
# dmgbuild writes the Finder window's .DS_Store straight into the image — no
# Finder, no AppleScript — so the layout comes out the same on a CI runner as
# on a laptop. dist/dmg.sh runs it as:
#
#   dmgbuild -s dist/dmg/settings.py \
#     -D app=dist/export/Myna.app -D background=dist/dmg/background.tiff \
#     -D icon=…/AppIcon.icns "Myna 0.5.0" dist/out/Myna-0.5.0.dmg
#
# The icon positions below must match the art in background.html: the app sits
# left of the arrow, the Applications link right of it, both on the teal band.
import os.path

app = defines["app"]  # noqa: F821 — `defines` is injected by dmgbuild
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
compression_level = 9

files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it sets com.apple.FinderInfo on Myna.app, which fails
# `codesign --verify --strict` ("resource fork, Finder information, or similar
# detritus not allowed") on the copy people drag out. Finder already hides
# ".app" unless someone has turned on "Show all filename extensions".

background = defines["background"]  # noqa: F821
icon = defines.get("icon") or None  # noqa: F821 — the mounted volume's icon

# The art is 660×420 pt; the extra 28 pt is Finder's title bar. Finder still
# adds the user's global tab / path / status bars inside that, whatever the
# show_* flags below say, which is why background.html keeps the icons high.
window_rect = ((200, 140), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True

arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (180, 210),
    "Applications": (480, 210),
}
