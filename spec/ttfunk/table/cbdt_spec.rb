# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cbdt'

RSpec.describe TTFunk::Table::Cbdt do
  # Build a font with a single strike. Each entry is a [data, image_format]
  # pair (or +nil+ for glyphs without a bitmap); each glyph gets its own
  # index subtable (format 1), like real fonts group glyphs by image format.
  def font_with_glyphs(entries)
    chunks = []
    subtables = []
    position = 4

    entries.each_with_index do |entry, index|
      next if entry.nil?

      data, image_format = entry
      subtables << {
        first: index + 1,
        last: index + 1,
        data: index_subtable(
          index_format: 1,
          image_format: image_format,
          image_data_offset: position,
          body: [0, data.bytesize].pack('N2'),
        ),
      }
      chunks << data
      position += data.bytesize
    end

    cbdt, = build_cbdt(chunks)
    build_font(
      'CBLC' => build_cblc([{ ppem: 16, bit_depth: 32, subtables: subtables }]),
      'CBDT' => cbdt,
    )
  end

  def bitmap_at(font, glyph_id)
    font.cblc.bitmap_for(glyph_id, ppem: 16).glyph
  end

  def compose_at(font, glyph_id)
    strike = font.cblc.strikes.first
    strike.bitmap_for(glyph_id)
      .compose(->(component_id) { strike.bitmap_for(component_id) })
  end

  it 'parses the table version' do
    font = build_font('CBDT' => build_cbdt([]).first)
    expect(font.cbdt.version).to eq(0x00020000)
  end

  it 'is nil when the font has no CBDT table' do
    font = build_font('CBLC' => build_cblc([]))
    expect(font.cbdt).to be_nil
  end

  describe 'image format 17 (small metrics + image data)' do
    it 'parses metrics and image data' do
      metrics = small_metrics(
        height: 10, width: 12, bearing_x: -1, bearing_y: 9, advance: 13,
      )
      font = font_with_glyphs([[image_glyph_17(metrics, 'PNGDATA'), 17]])

      glyph = bitmap_at(font, 1)
      expect(glyph).not_to be_composite
      expect(glyph.metrics.height).to eq(10)
      expect(glyph.metrics.width).to eq(12)
      expect(glyph.metrics.hori_bearing_x).to eq(-1)
      expect(glyph.metrics.hori_bearing_y).to eq(9)
      expect(glyph.metrics.hori_advance).to eq(13)
      expect(glyph.metrics.vert_advance).to be_nil
      expect(glyph.image_data).to eq('PNGDATA')
    end

    it 'raises on truncated image data' do
      glyph_data = image_glyph_17(small_metrics, 'PNGDATA')
      font = font_with_glyphs([[glyph_data.byteslice(0, 7), 17]])

      expect { bitmap_at(font, 1) }.to raise_error(TTFunk::Error, /truncated/)
    end
  end

  describe 'image format 18 (big metrics + image data)' do
    it 'parses horizontal and vertical metrics' do
      metrics = big_metrics(
        height: 10, width: 12,
        hori_bearing_x: -1, hori_bearing_y: 9, hori_advance: 13,
        vert_bearing_x: 5, vert_bearing_y: -6, vert_advance: 14,
      )
      font = font_with_glyphs([[image_glyph_18(metrics, 'PNGDATA'), 18]])

      glyph = bitmap_at(font, 1)
      expect(glyph.metrics.height).to eq(10)
      expect(glyph.metrics.width).to eq(12)
      expect(glyph.metrics.hori_bearing_x).to eq(-1)
      expect(glyph.metrics.hori_bearing_y).to eq(9)
      expect(glyph.metrics.hori_advance).to eq(13)
      expect(glyph.metrics.vert_bearing_x).to eq(5)
      expect(glyph.metrics.vert_bearing_y).to eq(-6)
      expect(glyph.metrics.vert_advance).to eq(14)
      expect(glyph.image_data).to eq('PNGDATA')
    end
  end

  describe 'image format 19 (image data only)' do
    it 'parses image data without metrics' do
      font = font_with_glyphs([[image_glyph_19('PNGDATA'), 19]])

      glyph = bitmap_at(font, 1)
      expect(glyph.metrics).to be_nil
      expect(glyph.image_data).to eq('PNGDATA')
    end
  end

  describe 'bitmap formats' do
    it 'parses format 1 (byte-aligned rows)' do
      pixels = [[1, 0, 1, 0, 1], [0, 1, 0, 1, 0]]
      metrics = small_metrics(height: 2, width: 5)
      font = font_with_glyphs([[bitmap_glyph(metrics, pixels), 1]])

      glyph = bitmap_at(font, 1)
      expect(glyph).to be_byte_aligned
      expect(glyph.width).to eq(5)
      expect(glyph.height).to eq(2)
      expect(glyph.pixels).to eq(pixels)
    end

    it 'parses format 2 (bit-aligned rows)' do
      pixels = [[1, 0, 1], [0, 1, 1]]
      metrics = small_metrics(height: 2, width: 3)
      font = font_with_glyphs([
        [bitmap_glyph(metrics, pixels, byte_aligned: false), 2],
      ])

      glyph = bitmap_at(font, 1)
      expect(glyph).not_to be_byte_aligned
      expect(glyph.pixels).to eq(pixels)
    end

    it 'parses format 6 (big metrics, byte-aligned rows)' do
      pixels = [[1, 1], [0, 1]]
      font = font_with_glyphs([[bitmap_glyph_big(big_metrics, pixels), 6]])

      glyph = bitmap_at(font, 1)
      expect(glyph.pixels).to eq(pixels)
      expect(glyph.metrics.vert_advance).to eq(5)
    end

    it 'parses format 7 (big metrics, bit-aligned rows)' do
      pixels = [[1, 1, 0], [0, 1, 0]]
      metrics = big_metrics(height: 2, width: 3)
      font = font_with_glyphs([
        [bitmap_glyph_big(metrics, pixels, byte_aligned: false), 7],
      ])

      expect(bitmap_at(font, 1).pixels).to eq(pixels)
    end

    it 'raises on truncated bitmap data' do
      metrics = small_metrics(height: 4, width: 8)
      font = font_with_glyphs([
        [bitmap_glyph(metrics, [[1] * 8] * 4).byteslice(0, 6), 1],
      ])

      expect { bitmap_at(font, 1) }.to raise_error(TTFunk::Error, /truncated/)
    end
  end

  describe 'composite glyphs' do
    let(:component_pixels_1) { [[1, 0], [0, 1]] }
    let(:component_pixels_2) { [[1, 1], [1, 1]] }

    def component_entries
      [
        [bitmap_glyph(small_metrics, component_pixels_1), 1],
        [bitmap_glyph(small_metrics, component_pixels_2), 1],
      ]
    end

    it 'parses format 8 components including negative offsets' do
      composite = composite_glyph_8(
        small_metrics,
        [{ glyph_id: 1, x: -3, y: 2 }, { glyph_id: 2, x: 0, y: -1 }],
      )
      font = font_with_glyphs([[composite, 8]])

      glyph = bitmap_at(font, 1)
      expect(glyph).to be_composite
      expect(glyph.components.size).to eq(2)
      expect(glyph.components[0].glyph_id).to eq(1)
      expect(glyph.components[0].x_offset).to eq(-3)
      expect(glyph.components[0].y_offset).to eq(2)
      expect(glyph.components[1].y_offset).to eq(-1)
    end

    it 'composes components with negative offsets and OR-ed overlaps' do
      composite = composite_glyph_9(
        big_metrics,
        [{ glyph_id: 1, x: 0, y: 0 }, { glyph_id: 2, x: -1, y: 1 }],
      )
      font = font_with_glyphs([*component_entries, [composite, 9]])

      bitmap = compose_at(font, 3)

      expect(bitmap.width).to eq(3)
      expect(bitmap.height).to eq(3)
      expect(bitmap.bearing_x).to eq(-1)
      expect(bitmap.bearing_y).to eq(3)
      expect(bitmap.pixels).to eq([
        [1, 1, 0],
        [1, 1, 0],
        [0, 0, 1],
      ])
    end

    it 'composes nested composites' do
      inner = composite_glyph_9(
        big_metrics,
        [{ glyph_id: 1, x: 0, y: 0 }, { glyph_id: 2, x: 2, y: 0 }],
      )
      outer = composite_glyph_9(
        big_metrics,
        [{ glyph_id: 3, x: 0, y: 0 }, { glyph_id: 1, x: 0, y: -3 }],
      )
      font = font_with_glyphs([*component_entries, [inner, 9], [outer, 9]])

      bitmap = compose_at(font, 4)

      expect(bitmap.width).to eq(4)
      expect(bitmap.height).to eq(5)
      expect(bitmap.bearing_x).to eq(0)
      expect(bitmap.bearing_y).to eq(2)
      expect(bitmap.pixels).to eq([
        [1, 0, 1, 1],
        [0, 1, 1, 1],
        [0, 0, 0, 0],
        [1, 0, 0, 0],
        [0, 1, 0, 0],
      ])
    end

    it 'raises on circular component references' do
      composite1 = composite_glyph_9(big_metrics, [{ glyph_id: 2, x: 0, y: 0 }])
      composite2 = composite_glyph_9(big_metrics, [{ glyph_id: 1, x: 0, y: 0 }])
      font = font_with_glyphs([[composite1, 9], [composite2, 9]])

      expect { compose_at(font, 1) }
        .to raise_error(TTFunk::Error, /circular/)
    end

    it 'raises on self-referencing composites' do
      composite = composite_glyph_9(big_metrics, [{ glyph_id: 1, x: 0, y: 0 }])
      font = font_with_glyphs([[composite, 9]])

      expect { compose_at(font, 1) }
        .to raise_error(TTFunk::Error, /circular/)
    end

    it 'raises on missing component glyphs' do
      composite = composite_glyph_9(big_metrics, [{ glyph_id: 99, x: 0, y: 0 }])
      font = font_with_glyphs([[composite, 9]])

      expect { compose_at(font, 1) }
        .to raise_error(TTFunk::Error, /not found/)
    end

    it 'raises on non-bitmap components' do
      image = image_glyph_17(small_metrics, 'PNG1')
      composite = composite_glyph_9(big_metrics, [{ glyph_id: 1, x: 0, y: 0 }])
      font = font_with_glyphs([[image, 17], [composite, 9]])

      expect { compose_at(font, 2) }
        .to raise_error(TTFunk::Error, /not a compositable bitmap/)
    end

    it 'raises on truncated component data' do
      composite = composite_glyph_9(
        big_metrics,
        [{ glyph_id: 1, x: 0, y: 0 }, { glyph_id: 2, x: 0, y: 0 }],
      )
      font = font_with_glyphs([[composite.byteslice(0, 12), 9]])

      expect { bitmap_at(font, 1) }.to raise_error(TTFunk::Error, /truncated/)
    end
  end

  describe 'unsupported image formats' do
    it 'raises on unknown image format' do
      font = font_with_glyphs([['DATA', 32]])

      expect { bitmap_at(font, 1) }
        .to raise_error(TTFunk::Error, /image format/)
    end
  end
end
