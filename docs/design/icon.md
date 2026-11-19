# Heat and bearing

The LifePath icon is one idea on one centre: a compass needle resting on a heat glow. The glow is the heat map's own
ramp, light core, cherry, satsuma and mustard fading to nothing, so it reads the way a place you return to glows in the
app. The needle points ahead at 40 degrees instead of standing to attention.

Everything is radial: the glow, the pivot and the needle all share the centre, so nothing pulls the eye elsewhere.
The glow has no hard edge, so it never reads as a target. Each half of the needle is cut into a lit and a shaded facet
with light from the upper left, the same side the soft shadow falls away from. North is paper white, south a deep
cherry brown, so the needle keeps its full silhouette over the glow at home-screen size.

Two looks share the drawing: Night (warm black ground) for dark mode, Paper (cream ground) for light mode. Both are
checked large, masked like iOS, and at 60 points on dark and light home screens.

Source: `icon.py` writes the SVGs; `render-icon.sh <night|paper> <out.png>` renders them with Edge at 1024 px. The
rendered icons live in `LifePath/Assets.xcassets/AppIcon.appiconset`.
