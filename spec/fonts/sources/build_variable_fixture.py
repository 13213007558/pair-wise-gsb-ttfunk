#!/usr/bin/env python3
"""Build VariableTwoAxes.ttf used by TTFunk's instantiation specs.

Two axes (wght 100..900 default 400, wdth 50..150 default 100) and one
simple outlined glyph A. gvar tuples cover shared point numbers, sparse
(inferred) deltas and phantom point metric variations. avar gives wght a
non-linear mapping near the low end.
"""
import os

from fontTools.fontBuilder import FontBuilder
from fontTools.ttLib import newTable
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables.TupleVariation import TupleVariation


def draw_a(pen):
    pen.moveTo((100, 0))
    pen.lineTo((100, 700))
    pen.lineTo((200, 700))
    pen.lineTo((200, 0))
    pen.closePath()


def output_path():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "VariableTwoAxes.ttf")


def build():
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder([".notdef", "A"])
    fb.setupCharacterMap({0x41: "A"})

    notdef_pen = TTGlyphPen(None)
    notdef_glyph = notdef_pen.glyph()
    notdef_glyph.numberOfContours = 0

    a_pen = TTGlyphPen(None)
    draw_a(a_pen)
    glyphs = {".notdef": notdef_glyph, "A": a_pen.glyph()}
    fb.setupGlyf(glyphs)

    fb.setupHorizontalMetrics({".notdef": (500, 0), "A": (500, 50)})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable(
        {"familyName": "Variable Two Axes", "styleName": "Regular"}
    )
    fb.setupOS2()
    fb.setupPost()

    fb.font["fvar"] = build_fvar()
    fb.font["avar"] = build_avar()
    fb.font["gvar"] = build_gvar()
    fb.font["HVAR"] = build_hvar(fb.font)
    fb.font.save(output_path())


def build_fvar():
    from fontTools.ttLib.tables._f_v_a_r import table__f_v_a_r, Axis

    fvar = table__f_v_a_r()
    fvar.axes = []
    for tag, minimum, default, maximum in (
        ("wght", 100, 400, 900),
        ("wdth", 50, 100, 150),
    ):
        axis = Axis()
        axis.axisTag = tag
        axis.minValue, axis.defaultValue, axis.maxValue = (
            minimum, default, maximum
        )
        axis.axisNameID = 0
        axis.flags = 0
        fvar.axes.append(axis)
    return fvar


def build_avar():
    avar = newTable("avar")
    avar.segments = {
        "wght": {-1.0: -1.0, -0.5: -0.75, 0.0: 0.0, 1.0: 1.0},
        "wdth": {-1.0: -1.0, 0.0: 0.0, 1.0: 1.0},
    }
    return avar


def build_gvar():
    gvar = newTable("gvar")
    # Outline points (4) followed by the four phantom points. Missing entries
    # are inferred from neighboring points (sparse deltas / IUP).
    weight = TupleVariation(
        {"wght": (0.0, 1.0, 1.0)},
        [
            (0, 0), (0, 0), (100, 0), (100, 0),
            (0, 0), (100, 0), None, None,
        ],
    )
    weight_min = TupleVariation(
        {"wght": (-1.0, -1.0, 0.0)},
        [
            (0, 0), (0, -50), (0, -50), (0, 0),
            (0, 0), (-50, 0), None, None,
        ],
    )
    width = TupleVariation(
        {"wdth": (0.0, 1.0, 1.0)},
        [
            None, None, (0, 200), None,
            (0, 0), (0, 100), None, None,
        ],
    )
    width_min = TupleVariation(
        {"wdth": (-1.0, -1.0, 0.0)},
        [
            None, None, (0, -100), None,
            (0, 0), (0, -100), None, None,
        ],
    )
    corner = TupleVariation(
        {
            "wght": (0.0, 1.0, 1.0),
            "wdth": (0.0, 1.0, 1.0),
        },
        [
            (0, 0), (0, -100), (0, 100), (0, -100),
            None, None, None, None,
        ],
    )
    gvar.variations = {
        ".notdef": [],
        "A": [weight, weight_min, width, width_min, corner],
    }
    return gvar


def build_hvar(font):
    """Advance width for A follows wght directly (+80 at wght=900) while gvar's
    right phantom point encodes a *different* +100. A conforming implementation
    must use HVAR and ignore the phantom advance delta.
    """
    from fontTools.varLib import builder
    from fontTools.ttLib.tables import otTables as ot
    from fontTools.ttLib import newTable

    axis_tags = [axis.axisTag for axis in font["fvar"].axes]
    support = {tag: (0.0, 1.0 if tag == "wght" else 0.0, 1.0) for tag in axis_tags}
    regions = builder.buildVarRegionList([support], axis_tags)
    data = builder.buildVarData([0], [[0], [80]], optimize=False)
    store = builder.buildVarStore(regions, [data])

    hvar = newTable("HVAR")
    table = ot.HVAR()
    table.Version = 0x00010000
    table.VarStore = store
    table.AdvWidthMap = None
    table.LsbMap = None
    table.RsbMap = None
    hvar.table = table
    return hvar


if __name__ == "__main__":
    build()
    print(output_path())
