#!/bin/bash
# Showreel scenes for the README (used by scripts/make-media.sh). One scene per line:
# name | --only modules | --set values | --mod routes
cat <<'SCENES'
orbit|spin,echo,chroma,palette|spin.rings=3,spin.counter=1,spin.rainbow=1,spin.count=10,spin.size=0.04,echo.feedback=0.9,echo.zoom=0.012,echo.rotate=25,palette.preset=0,palette.spread=1|spin.radius=lfo1:0.25
tunnel|rings,kaleido,glow,palette|rings.tunnel=1,rings.twist=0.4,rings.rainbow=1,kaleido.segments=6,glow.amount=1.5,palette.preset=7|rings.speed=lfo2:0.3
spiral|bars,polar,chroma,palette|bars.count=12,bars.width=0.4,bars.rainbow=1,polar.mode=1,polar.twist=0.6,chroma.amount=0.01,palette.preset=1|
stars|stars,glow,crt,palette|stars.speed=0.6,stars.streak=0.8,stars.rainbow=1,glow.amount=1.2,palette.preset=2|
liss|lissajous,echo,palette|lissajous.thick=0.5,lissajous.rainbow=1,echo.feedback=0.9,echo.zoom=-0.008,echo.rotate=-20,palette.preset=5|lissajous.size=lfo3:0.15
shapes|shapes,plasma,glow,palette|shapes.rainbow=1,shapes.thick=0.5,plasma.style=2,plasma.rainbow=1,glow.amount=1.4,palette.preset=3|shapes.size=env:0.4
SCENES
