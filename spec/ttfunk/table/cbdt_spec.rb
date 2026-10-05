# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/cbdt_font_builder'

RSpec.describe TTFunk::Table::Cbdt do
  let(:builder) { CbdtFontBuilder.new(20) }

  def metrics(attrs = {})
    CbdtFontBuilder.metrics(attrs)
  end

  # Build a 1bpp bitmap string of the given rows. Rows are arrays of
  # characters, "#" being an inked pixel.
  def mono_bitmap(rows)
    width = rows.first.length
    rows.map { |row|
      byte = 0
      width.times { |x| byte |= (1 << (7 - x)) if row[x] == '#' }
      byte
    }.pack('C*')
  end

  def build_font(bit_depth: 1, ppem: 16, entries_by_format: {},
                 subtables: nil)
    subtables ||= entries_by_format.map do |image_format, entries|
      index_format = [1, 2, 5, 6, 7, 16, 17].include?(image_format) ? 1 : 1
      CbdtFontBuilder::Subtable.new(
        index_format: index_format,
        image_format: image_format,
        entries: entries,
      )
    end
    builder.add_strike(
      ppem: ppem, bit_depth: bit_depth, subtables: subtables
    )
    TTFunk::File.open(StringIO.new(builder.build))
  end

  describe 'direct images' do
    it 'reads a small metrics byte-aligned bitmap (format 1)' do
      bitmap = mono_bitmap(['##..', '##..', '....', '....'])
      glyph_metrics = metrics(
        width: 4, height: 4, horizontal_bearing_x: 1, horizontal_bearing_y: 14
      )
      font = build_font(
        entries_by_format: {
          1 => [
            CbdtFontBuilder::Entry.new(
              glyph_id: 2,
              payload: CbdtFontBuilder.small_payload(1, glyph_metrics, bitmap),
              metrics: glyph_metrics,
            ),
          ],
        }
      )

      bitmap_data = font.color_bitmap_data.bitmap_data_for(2, 16, bit_depth: 1)
      expect(bitmap_data.format).to eq(1)
      expect(bitmap_data.data).to eq(bitmap)
      expect(bitmap_data.metrics.width).to eq(4)
      expect(bitmap_data.metrics.height).to eq(4)
      expect(bitmap_data.strike.bit_depth).to eq(1)
      expect(bitmap_data.composite?).to eq(false)
    end

    it 'derives vertical metrics from the strike line metrics' do
      bitmap = mono_bitmap(['##', '##'])
      glyph_metrics = metrics(
        width: 2, height: 2,
        horizontal_bearing_x: 1, horizontal_bearing_y: 14,
        horizontal_advance: 16
      )
      font = build_font(
        entries_by_format: {
          1 => [
            CbdtFontBuilder::Entry.new(
              glyph_id: 2,
              payload: CbdtFontBuilder.small_payload(1, glyph_metrics, bitmap),
              metrics: glyph_metrics,
            ),
          ],
        }
      )

      bitmap_data = font.color_bitmap_data.bitmap_data_for(2, 16)
      # vertBearingX = bearingX + (advance - width) / 2
      expect(bitmap_data.metrics.vertical_bearing_x).to eq(8)
      # vertBearingY = bearingY + hori.ascender - vert.ascender
      expect(bitmap_data.metrics.vertical_bearing_y).to eq(14)
      # vertAdvance = hori.ascender - hori.descender
      expect(bitmap_data.metrics.vertical_advance).to eq(18)
    end

    it 'reads a big metrics bitmap (format 6)' do
      bitmap = mono_bitmap(['##', '##'])
      glyph_metrics = metrics(
        width: 2, height: 2, vertical_bearing_x: 7, vertical_bearing_y: -1
      )
      font = build_font(
        entries_by_format: {
          6 => [
            CbdtFontBuilder::Entry.new(
              glyph_id: 3,
              payload: CbdtFontBuilder.big_payload(6, glyph_metrics, bitmap),
              metrics: glyph_metrics,
            ),
          ],
        }
      )

      bitmap_data = font.color_bitmap_data.bitmap_data_for(3, 16)
      expect(bitmap_data.format).to eq(6)
      expect(bitmap_data.data).to eq(bitmap)
      expect(bitmap_data.metrics.vertical_bearing_x).to eq(7)
      expect(bitmap_data.metrics.vertical_bearing_y).to eq(-1)
    end

    it 'reads a PNG image with big metrics (format 17)' do
      png = "\x89PNG\r\n\x1a\npng-bytes".b
      glyph_metrics = metrics(width: 4, height: 4)
      font = build_font(
        bit_depth: 32,
        entries_by_format: {
          17 => [
            CbdtFontBuilder::Entry.new(
              glyph_id: 4,
              payload: CbdtFontBuilder.big_payload(17, glyph_metrics, png, png: true),
              metrics: glyph_metrics,
            ),
          ],
        }
      )

      bitmap_data = font.color_bitmap_data.bitmap_data_for(4, 16)
      expect(bitmap_data).to be_png
      expect(bitmap_data.data).to eq(png)
    end

    it 'reads a PNG image with small metrics (format 16)' do
      png = "\x89PNG\r\n\x1a\nsmall-png".b
      glyph_metrics = metrics(width: 3, height: 3)
      font = build_font(
        bit_depth: 32,
        entries_by_format: {
          16 => [
            CbdtFontBuilder::Entry.new(
              glyph_id: 5,
              payload: CbdtFontBuilder.small_payload(
                16, glyph_metrics, png, png: true
              ),
              metrics: glyph_metrics,
            ),
          ],
        }
      )

      bitmap_data = font.color_bitmap_data.bitmap_data_for(5, 16)
      expect(bitmap_data).to be_png
      expect(bitmap_data.format).to eq(16)
      expect(bitmap_data.data).to eq(png)
    end
  end

  describe 'composite images' do
    # Two 2x2 component blocks placed inside a 4x4 composite glyph.
    let(:top_left) do
      bitmap = mono_bitmap(['##', '##'])
      glyph_metrics = metrics(
        width: 2, height: 2,
        horizontal_bearing_x: 0, horizontal_bearing_y: 14
      )
      CbdtFontBuilder::Entry.new(
        glyph_id: 2,
        payload: CbdtFontBuilder.big_payload(6, glyph_metrics, bitmap),
        metrics: glyph_metrics,
      )
    end

    let(:bottom_right) do
      bitmap = mono_bitmap(['##', '##'])
      glyph_metrics = metrics(
        width: 2, height: 2,
        horizontal_bearing_x: 0, horizontal_bearing_y: 13
      )
      CbdtFontBuilder::Entry.new(
        glyph_id: 3,
        payload: CbdtFontBuilder.big_payload(6, glyph_metrics, bitmap),
        metrics: glyph_metrics,
      )
    end

    let(:composite_metrics) do
      metrics(width: 4, height: 4)
    end

    def composite_font
      components = [
        CbdtFontBuilder::ComponentData.new(
          glyph_id: 2, x_offset: 0, y_offset: 0
        ),
        # Shift the second block so it overlaps the first by one pixel.
        # The overlap is resolved with a Boolean OR.
        CbdtFontBuilder::ComponentData.new(
          glyph_id: 3, x_offset: 2, y_offset: -1
        ),
      ]
      composite = CbdtFontBuilder::Entry.new(
        glyph_id: 5,
        payload: CbdtFontBuilder.composite_payload(9, composite_metrics, components),
        metrics: composite_metrics,
      )

      build_font(
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 6,
            entries: [top_left, bottom_right]
          ),
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 9, entries: [composite]
          ),
        ]
      )
    end

    it 'composites components with negative offsets and OR overlap' do
      bitmap_data = composite_font.color_bitmap_data.glyph_data_for(5)
      expect(bitmap_data).to be_composite
      expect(bitmap_data.components.map(&:glyph_id)).to eq([2, 3])
      expect(bitmap_data.components.map(&:x_offset)).to eq([0, 2])

      rows = bitmap_data.data.bytes.map { |byte|
        4.times.map { |x| byte & (0x80 >> x) != 0 ? '#' : '.' }.join
      }
      expect(rows.first(2)).to eq(%w[#### ####])
    end

    it 'handles negative component offsets and clips at the bitmap edges' do
      components = [
        CbdtFontBuilder::ComponentData.new(
          glyph_id: 2, x_offset: -1, y_offset: 0
        ),
      ]
      composite = CbdtFontBuilder::Entry.new(
        glyph_id: 5,
        payload: CbdtFontBuilder.composite_payload(9, composite_metrics, components),
        metrics: composite_metrics,
      )
      font = build_font(
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 6, entries: [top_left]
          ),
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 9, entries: [composite]
          ),
        ]
      )

      bitmap_data = font.color_bitmap_data.glyph_data_for(5)
      expect(bitmap_data.components.first.x_offset).to eq(-1)
      rows = bitmap_data.data.bytes.first(2).map { |byte|
        4.times.map { |x| byte & (0x80 >> x) != 0 ? '#' : '.' }.join
      }
      # The 2px wide block starts one pixel left of the canvas, so only its
      # right column is visible.
      expect(rows).to eq(%w[#... #...])
    end

    it 'reads a small metrics composite with the format 8 padding byte' do
      bitmap = mono_bitmap(['##', '##'])
      component_metrics = metrics(
        width: 2, height: 2,
        horizontal_bearing_x: 0, horizontal_bearing_y: 14
      )
      component = CbdtFontBuilder::Entry.new(
        glyph_id: 2,
        payload: CbdtFontBuilder.small_payload(1, component_metrics, bitmap),
        metrics: component_metrics,
      )
      parent_metrics = metrics(
        width: 2, height: 2,
        horizontal_bearing_x: 0, horizontal_bearing_y: 14
      )
      composite_entry = CbdtFontBuilder::Entry.new(
        glyph_id: 5,
        payload: CbdtFontBuilder.composite_payload(
          8,
          parent_metrics,
          [CbdtFontBuilder::ComponentData.new(glyph_id: 2, x_offset: 0, y_offset: 0)]
        ),
        metrics: parent_metrics,
      )
      font = build_font(
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 1, entries: [component]
          ),
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 8, entries: [composite_entry]
          ),
        ]
      )

      bitmap_data = font.color_bitmap_data.glyph_data_for(5)
      expect(bitmap_data.format).to eq(8)
      expect(bitmap_data.components.first.glyph_id).to eq(2)
      rows = bitmap_data.data.bytes.map { |byte|
        2.times.map { |x| byte & (0x80 >> x) != 0 ? '#' : '.' }.join
      }
      expect(rows).to eq(%w[## ##])
    end

    it 'resolves component references through the sparse index format 5' do
      # Build format 19 fixed-size composite referenced by index format 5.
      components = [
        CbdtFontBuilder::ComponentData.new(glyph_id: 2, x_offset: 0, y_offset: 0),
      ]
      payload = CbdtFontBuilder.composite_payload(
        19, composite_metrics, components
      )
      fixed = payload.ljust(8, "\0".b)
      composite = CbdtFontBuilder::Entry.new(
        glyph_id: 8, payload: fixed, metrics: composite_metrics
      )
      font = build_font(
        bit_depth: 32,
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 17,
            entries: [
              CbdtFontBuilder::Entry.new(
                glyph_id: 2,
                payload: CbdtFontBuilder.big_payload(
                  17, metrics(width: 2, height: 2),
                  "\x89PNGchild".b, png: true
                ),
                metrics: metrics(width: 2, height: 2),
              ),
            ]
          ),
          CbdtFontBuilder::Subtable.new(
            index_format: 5, image_format: 19, fixed_size: 8,
            fixed_metrics: composite_metrics, entries: [composite]
          ),
        ]
      )

      bitmap_data = font.color_bitmap_data.glyph_data_for(8)
      expect(bitmap_data.format).to eq(19)
      expect(bitmap_data).to be_composite
      # The only component is a PNG glyph, so no raster is composited.
      expect(bitmap_data.data).to be_nil
      expect(bitmap_data.components.first.glyph_id).to eq(2)
    end

    it 'overwrites overlapping color pixels with the last component' do
      # Two 2x2 BGRA blocks. The second block overlaps the first by one row
      # and, for color images, replaces rather than ORs the overlap.
      blue = ([0xFF, 0x00, 0x00, 0xFF] * 4).pack('C*')
      red = ([0x00, 0x00, 0xFF, 0xFF] * 4).pack('C*')
      m2 = metrics(
        width: 2, height: 2,
        horizontal_bearing_x: 0, horizontal_bearing_y: 13
      )
      first_block = CbdtFontBuilder::Entry.new(
        glyph_id: 2,
        payload: CbdtFontBuilder.big_payload(6, m2, blue),
        metrics: m2,
      )
      second_block = CbdtFontBuilder::Entry.new(
        glyph_id: 3,
        payload: CbdtFontBuilder.big_payload(6, m2, red),
        metrics: m2,
      )
      parent_metrics = metrics(
        width: 2, height: 3,
        horizontal_bearing_x: 0, horizontal_bearing_y: 13
      )
      components = [
        CbdtFontBuilder::ComponentData.new(glyph_id: 2, x_offset: 0, y_offset: 0),
        CbdtFontBuilder::ComponentData.new(glyph_id: 3, x_offset: 0, y_offset: 1),
      ]
      composite = CbdtFontBuilder::Entry.new(
        glyph_id: 6,
        payload: CbdtFontBuilder.composite_payload(
          18, parent_metrics, components
        ),
        metrics: parent_metrics,
      )
      font = build_font(
        bit_depth: 32,
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 6,
            entries: [first_block, second_block]
          ),
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 18, entries: [composite]
          ),
        ]
      )

      bitmap_data = font.color_bitmap_data.glyph_data_for(6)
      expect(bitmap_data.format).to eq(18)
      # Row 0 comes only from the first block, row 1 from the second.
      row_size = 2 * 4
      expect(bitmap_data.data.byteslice(0, row_size)).to eq(blue.byteslice(0, row_size))
      expect(bitmap_data.data.byteslice(row_size, row_size))
        .to eq(red.byteslice(0, row_size))
    end
  end

  describe 'malformed data' do
    def simple_font
      bitmap = mono_bitmap(['##', '##'])
      glyph_metrics = metrics
      build_font(
        entries_by_format: {
          6 => [
            CbdtFontBuilder::Entry.new(
              glyph_id: 2,
              payload: CbdtFontBuilder.big_payload(6, glyph_metrics, bitmap),
              metrics: glyph_metrics,
            ),
          ],
        }
      )
    end

    it 'raises when image data extends past the CBDT table' do
      font = simple_font
      bytes = font.contents.string
      # The first image data offset lives at the start of the index subtable
      # header; push it beyond the end of the table.
      cblc_info = font.directory_info('CBLC')
      bytes.setbyte(cblc_info[:offset] + 64 + 4, 0xFF)
      bytes.setbyte(cblc_info[:offset] + 64 + 7, 0xFF)

      reloaded = TTFunk::File.open(StringIO.new(bytes))
      expect { reloaded.color_bitmap_data.glyph_data_for(2) }
        .to raise_error(TTFunk::Error, /truncated|invalid/i)
    end

    it 'raises when components form a recursive cycle' do
      # Glyph 2 is declared as a format 9 composite referencing itself.
      component = CbdtFontBuilder::ComponentData.new(
        glyph_id: 2, x_offset: 0, y_offset: 0
      )
      payload = CbdtFontBuilder.composite_payload(9, metrics, [component])
      font = build_font(
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 9,
            entries: [
              CbdtFontBuilder::Entry.new(
                glyph_id: 2, payload: payload, metrics: metrics
              ),
            ]
          ),
        ]
      )

      expect { font.color_bitmap_data.glyph_data_for(2) }
        .to raise_error(TTFunk::Error, /cycle/i)
    end

    it 'raises when a component references a missing glyph' do
      component = CbdtFontBuilder::ComponentData.new(
        glyph_id: 9, x_offset: 0, y_offset: 0
      )
      payload = CbdtFontBuilder.composite_payload(9, metrics, [component])
      font = build_font(
        subtables: [
          CbdtFontBuilder::Subtable.new(
            index_format: 1, image_format: 9,
            entries: [
              CbdtFontBuilder::Entry.new(
                glyph_id: 2, payload: payload, metrics: metrics
              ),
            ]
          ),
        ]
      )

      expect { font.color_bitmap_data.glyph_data_for(2) }
        .to raise_error(TTFunk::Error, /without bitmap data/i)
    end
  end
end
