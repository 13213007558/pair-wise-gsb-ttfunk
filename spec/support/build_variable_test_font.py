"""Build a small, deterministic variable TrueType font for the test suite.

The font exercises every code path required of a static instance:
  - fvar with a wght axis (default 400, min 100, max 900),
  - an avar table that warps the normalized axis
    (0.5 -> 0.7), so interpolation must honor avar,
  - gvar with embedded peak tuples, intermediate regions, PRIVATE point
    numbers and IUP-omitted points,
  - phantom-point deltas that change the advance width at heavy weights,
  - a composite glyph (base + combining mark) whose component moves,
  - an empty glyph (space) with a phantom width delta.
"""
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphCoordinates
from fontTools.ttLib.tables.TupleVariation import TupleVariation
from fontTools.ttLib import newTable

fb = FontBuilder(1000, isTTF=True)
fb.setupGlyphOrder([
    '.notdef', 'space', 'mark', 'base', 'base.mark',
])
fb.setupCharacterMap({0x20: 'space', 0x62: 'base', 0xE000: 'base.mark'})

# Simple outlines.
def glyph(points, contours):
    pen = TTGlyphPen(None)
    start = 0
    for end in contours:
        pen.moveTo(points[start])
        for p in points[start + 1:end + 1]:
            pen.lineTo(p)
        pen.closePath()
        start = end + 1
    return pen.glyph()

# base: rectangle (0,0)-(600,700), 4 points, contour end 3
base = glyph([(0, 0), (600, 0), (600, 700), (0, 700)], [3])
# mark: small triangle above the base, 3 points
mark = glyph([(200, 700), (400, 700), (300, 800)], [2])
space = Glyph()
notdef = glyph([(0, 0), (500, 0), (500, 500), (0, 500)], [3])

# Composite base.mark: base at (0,0) + mark translated (50, -50).
cp = TTGlyphPen({'base': None, 'mark': None})
cp.addComponent('base', (1, 0, 0, 1, 0, 0))
cp.addComponent('mark', (1, 0, 0, 1, 50, -50))
composite = cp.glyph()

glyphs = {
    '.notdef': notdef,
    'space': space,
    'mark': mark,
    'base': base,
    'base.mark': composite,
}

advance_widths = {n: 0 for n in glyphs}
left_side_bearings = {n: 0 for n in glyphs}
advance_widths.update({
    'space': 300,
    'base': 600,
    'mark': 200,
    'base.mark': 650,
    '.notdef': 500,
})
fb.setupGlyf(glyphs)
metrics = {n: (advance_widths[n], left_side_bearings[n]) for n in glyphs}
fb.setupHorizontalMetrics(metrics)
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({'familyName': 'VariableTest', 'styleName': 'Regular'})
fb.setupOS2()
fb.setupPost()
fb.setupMaxp()

font = fb.font

# fvar: wght 100..900, default 400
fvar = newTable('fvar')
fvar.majorVersion = 1
fvar.minorVersion = 0
from fontTools.ttLib.tables._f_v_a_r import Axis as FvarAxis, NamedInstance
ax = FvarAxis()
ax.axisTag = 'wght'
ax.minValue = 100
ax.defaultValue = 400
ax.maxValue = 900
ax.flags = 0
ax.axisNameID = 256
fvar.axes = [ax]
ni = NamedInstance()
ni.subfamilyNameID = 257
ni.flags = 0
ni.coordinates = {'wght': 900}
ni.postscriptNameID = 0xFFFF
fvar.instances = [ni]
font['fvar'] = fvar

# name records for 256/257
name = font['name']
name.setName('Weight', 256, 3, 1, 0x409)
name.setName('Black', 257, 3, 1, 0x409)

# avar: map 0.5 -> 0.7
avar = newTable('avar')
avar.majorVersion = 1
avar.minorVersion = 0
avar.segments = {'wght': {-1: -1, 0: 0, 0.5: 0.7, 1: 1}}
font['avar'] = avar

# gvar: define tuple variations per glyph. Coordinates include phantoms.
gvar = newTable('gvar')
gvar.version = 1
gvar.reserved = 0
gvar.variations = {}

def phantoms(font, name):
    hmtx = font['hmtx'].metrics
    g = font['glyf'][name]
    return hmtx[name][0]

# base: 4 outline points + 4 phantoms = 8 coordinates.
# Heavy tuple shifts outline and widens advance by +100.
heavy_base = [
    (0, 0), (10, 0), (10, 10), (0, 10),   # small outline grow
    (0, 0), (100, 0), (0, 0), (0, 0),       # phantom: width +100
]
# Light tuple: negative shifts, no width change.
light_base = [
    (0, 0), (-10, 0), (-10, -10), (0, -10),
    (0, 0), (0, 0), (0, 0), (0, 0),
]
gvar.variations['base'] = [
    TupleVariation({'wght': (0.0, 1.0, 1.0)}, heavy_base),
    TupleVariation({'wght': (-1.0, -1.0, 0.0)}, light_base),
]

# mark: 3 points + 4 phantoms = 7; omit point index 1 (IUP) in heavy.
heavy_mark = [
    (0, 20), None, (0, 20),
    (0, 0), (0, 0), (0, 0), (0, 0),
]
gvar.variations['mark'] = [
    TupleVariation({'wght': (0.0, 1.0, 1.0)}, heavy_mark),
]

# space: 4 phantom coordinates; widen by +120 at heavy.
gvar.variations['space'] = [
    TupleVariation({'wght': (0.0, 1.0, 1.0)},
                   [None, (120, 0), None, None]),
]

# composite: 2 component pseudo-points + 4 phantoms = 6.
# move the mark (index 1) by (30, 40), widen +20.
heavy_comp = [
    (0, 0), (30, 40),
    (0, 0), (20, 0), (0, 0), (0, 0),
]
gvar.variations['base.mark'] = [
    TupleVariation({'wght': (0.0, 1.0, 1.0)}, heavy_comp),
]

gvar.variations['.notdef'] = []
gvar.sharedTuples = []
gvar.offsetToSharedTuples = 0
gvar.glyphCount = len(glyphs)
gvar.flags = 0
font['gvar'] = gvar

# cvt + cvar: four control values, the heavy tuple adds a flat +7 to all of
# them. This exercises the cvt adjustment path.
cvt = newTable('cvt ')
cvt.version = 0
import array
cvt.values = array.array('h', [100, -50, 0, 200])
font['cvt '] = cvt

cvar = newTable('cvar')
cvar.majorVersion = 1
cvar.minorVersion = 0
cvar.variations = [
    TupleVariation({'wght': (0.0, 1.0, 1.0)}, [7, 7, 7, 7]),
]
font['cvar'] = cvar

import os
out = os.path.join(os.path.dirname(__file__), '..', 'fonts',
                   'VariableTest.ttf')
font.save(out)
print('wrote', os.path.normpath(out))
