# Instrument Warmth

The LifePath icon is drawn like a brass field instrument: a compass rose on a dial, with one walk glowing across the face. It belongs to the palette of the app itself: satsuma and cherry for the north point, mustard for the intercardinals, paper and ink for the rest.

Every point of the rose is cut into two facets, one in light and one in shade, so the star reads as a raised object without outlines. The brass ring takes the same light from the upper left, with a thin sheen along its top edge and a soft shadow inside the face. Depth comes from shading alone, in the manner of a well-made physical object.

The trail is the quiet reference. It starts as faint mustard at the edge of the dial and warms to satsuma and cherry where it reaches the centre: the heat map's ramp, drawn as one route that ends where you stand.

Two looks share one drawing. Night (warm black face, paper-white points) is the dark-mode icon; Paper (cream face, ink points) is the light-mode icon. Each detail is tuned at full size and checked at home-screen size with the iOS corner mask, so the rose, the red north and the glowing trail still read at 60 points.

Source: `icon.py` writes the SVGs; `render-icon.sh <night|paper> <out.png>` renders them with Edge at 1024 px. The rendered icons live in `LifePath/Assets.xcassets/AppIcon.appiconset`.
