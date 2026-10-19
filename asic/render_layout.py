"""Render a GDS layout to PNG with KLayout (batch mode).

    klayout -zz -r asic/render_layout.py -rd gds=<file.gds> -rd lyp=<sky130A.lyp> \
            -rd out=<out.png> [-rd size=1600] [-rd layers=all|cells]

layers=all   : every layer with the PDK's colours (default)
layers=cells : only diffusion / poly / local interconnect, which shows where the
               standard cells sit without the metal routing on top
"""

import pya

gds = pya.Application.instance().get_config("gds") if False else gds      # noqa: F821  (set by -rd)
size = int(globals().get("size", "1600"))
mode = globals().get("layers", "all")

view = pya.LayoutView()
view.load_layout(gds, 0)
view.load_layer_props(lyp)                                                 # noqa: F821
view.max_hier()
view.set_config("background-color", "#ffffff")
view.set_config("grid-visible", "false")
view.set_config("text-visible", "false")

if mode == "cells":
    keep = {"diff", "tap", "poly", "li1", "nwell"}
    it = view.begin_layers()
    while not it.at_end():
        lp = it.current()
        name = (lp.name or "").split(" ")[0].split(".")[0].lower()
        lp.visible = any(name.startswith(k) for k in keep)
        view.set_layer_properties(it, lp)
        it.next()

view.zoom_fit()
view.save_image(out, size, size)                                           # noqa: F821
print(f"wrote {out}")                                                      # noqa: F821
