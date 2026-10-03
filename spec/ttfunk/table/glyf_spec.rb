# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::Table::Glyf do
  let(:compound_flags) { TTFunk::Table::Glyf::Compound }

  # Converts a float to a raw F2DOT14 fixed-point value.
  def f2dot14(value)
    (value * 16_384).round
  end

  # Builds a raw simple glyph from contours of [x, y, on_curve] points.
  def simple_glyph(contours)
    points = contours.flatten(1)
    end_points = []
    point_count = 0
    contours.each do |contour|
      point_count += contour.length
      end_points << (point_count - 1)
    end

    xs = points.map(&:first)
    ys = points.map { |point| point[1] }

    raw = [contours.length, xs.min, ys.min, xs.max, ys.max].pack('n*')
    raw << end_points.pack('n*')
    raw << [0].pack('n') # instruction length

    flags = +''.b
    x_bytes = +''.b
    y_bytes = +''.b
    prev_x = 0
    prev_y = 0

    points.each do |(x, y, on)|
      flag = on ? 1 : 0

      dx = x - prev_x
      prev_x = x
      if dx.zero?
        flag |= 0x10
      else
        x_bytes << [dx].pack('n')
      end

      dy = y - prev_y
      prev_y = y
      if dy.zero?
        flag |= 0x20
      else
        y_bytes << [dy].pack('n')
      end

      flags << flag
    end

    raw << flags << x_bytes << y_bytes
    raw
  end

  # Builds a raw compound glyph. Each component is a hash with :flags,
  # :glyph, :arg1, :arg2, and an optional :transform of raw F2DOT14 values.
  def compound_glyph(components)
    raw = [-1, 0, 0, 0, 0].pack('n*')

    components.each_with_index do |component, index|
      flags = component[:flags]
      if index < components.length - 1
        flags |= TTFunk::Table::Glyf::Compound::MORE_COMPONENTS
      end

      raw << [flags, component[:glyph]].pack('n*')
      raw << [component[:arg1] || 0, component[:arg2] || 0].pack('n*')
      raw << component[:transform].pack('n*') if component[:transform]
    end

    raw
  end

  # Builds a minimal in-memory TrueType font from raw glyph data and
  # horizontal metrics ([advance_width, lsb] per glyph).
  def build_font(glyphs, metrics)
    glyf = +''.b
    offsets = []
    glyphs.each do |raw|
      offsets << glyf.length
      glyf << raw if raw
    end
    offsets << glyf.length

    head =
      [0x00010000, 0x00010000, 0, 0x5F0F3CF5, 0, 1000, 0, 0].pack('N4n2q>2') <<
      [0, 0, 1000, 1000].pack('n*') <<
      [0, 8, 2, 1, 0].pack('n*')

    hhea =
      [0x00010000].pack('N') <<
      [800, -200, 0].pack('n*') <<
      [1000].pack('n*') <<
      [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0].pack('n*') <<
      [metrics.length].pack('n*')

    maxp = [0x00010000, glyphs.length].pack('Nn') << [0].pack('n*') * 13

    hmtx = metrics.map { |aw, lsb| [aw, lsb].pack('n*') }.join

    loca = offsets.pack('N*')

    tables = {
      'glyf' => glyf, 'head' => head, 'hhea' => hhea,
      'hmtx' => hmtx, 'loca' => loca, 'maxp' => maxp,
    }

    font = [0x00010000, tables.length, 0, 0, 0].pack('Nnnnn')
    directory = +''.b
    offset = font.length + (tables.length * 16)
    tables.each do |tag, data|
      directory << [tag, 0, offset, data.length].pack('a4N*')
      offset += data.length
    end

    TTFunk::File.new(font << directory << tables.values.join)
  end

  let(:words) { compound_flags::ARG_1_AND_2_ARE_WORDS }
  let(:xy) { words | compound_flags::ARGS_ARE_XY_VALUES }

  # glyph 1: simple triangle
  let(:triangle) { simple_glyph([[[0, 0, true], [100, 0, true], [0, 100, true]]]) }
  # glyph 2: simple two-point glyph at (500, 500)
  let(:anchor_base) { simple_glyph([[[500, 500, true], [600, 500, true]]]) }

  let(:font) do
    build_font(
      [
        nil, # 0: .notdef (empty)
        triangle, # 1
        anchor_base, # 2
        # 3: anchor_base at (0, 0) + rotated triangle anchored to point 0
        compound_glyph([
          { flags: xy, glyph: 2, arg1: 0, arg2: 0 },
          {
            flags: words | compound_flags::WE_HAVE_A_TWO_BY_TWO,
            glyph: 1, arg1: 0, arg2: 0,
            transform: [f2dot14(0), f2dot14(-1), f2dot14(1), f2dot14(0)],
          },
        ]),
        # 4: triangle mirrored with a negative scale
        compound_glyph([
          {
            flags: xy | compound_flags::WE_HAVE_A_SCALE,
            glyph: 1, arg1: 0, arg2: 0, transform: [f2dot14(-1)],
          },
        ]),
        # 5: triangle scaled 1.5x with a scaled offset
        compound_glyph([
          {
            flags: xy | compound_flags::WE_HAVE_A_SCALE |
              compound_flags::SCALED_COMPONENT_OFFSET,
            glyph: 1, arg1: 10, arg2: 20, transform: [f2dot14(1.5)],
          },
        ]),
        # 6: triangle scaled 1.5x with an unscaled offset
        compound_glyph([
          {
            flags: xy | compound_flags::WE_HAVE_A_SCALE |
              compound_flags::UNSCALED_COMPONENT_OFFSET,
            glyph: 1, arg1: 10, arg2: 20, transform: [f2dot14(1.5)],
          },
        ]),
        # 7: triangle contributing its metrics via USE_MY_METRICS
        compound_glyph([
          {
            flags: xy | compound_flags::USE_MY_METRICS,
            glyph: 1, arg1: 0, arg2: 0,
          },
        ]),
        # 8: nested compound (references glyph 4)
        compound_glyph([
          { flags: xy, glyph: 4, arg1: 1000, arg2: 0 },
        ]),
        # 9: self-referencing compound
        compound_glyph([
          { flags: xy, glyph: 9, arg1: 0, arg2: 0 },
        ]),
        # 10: mutually recursive with glyph 11
        compound_glyph([
          { flags: xy, glyph: 11, arg1: 0, arg2: 0 },
        ]),
        # 11: references glyph 10
        compound_glyph([
          { flags: xy, glyph: 10, arg1: 0, arg2: 0 },
        ]),
        # 12: anchored component with an out of range parent point
        compound_glyph([
          { flags: words, glyph: 1, arg1: 5, arg2: 0 },
        ]),
        # 13: anchored component with an out of range component point
        compound_glyph([
          { flags: xy, glyph: 2, arg1: 0, arg2: 0 },
          { flags: words, glyph: 1, arg1: 0, arg2: 10 },
        ]),
      ],
      [
        [500, 0], [600, 10], [500, 0], [1000, 50], [700, 20], [700, 20],
        [700, 20], [1000, 50], [900, 40], [500, 0], [500, 0], [500, 0],
        [500, 0], [500, 0],
      ],
    )
  end

  def outline_of(glyph_id)
    font.glyph_outlines.for(glyph_id).expand
  end

  describe 'simple glyph expansion' do
    it 'returns points, contour boundaries, on-curve flags, and metrics' do
      outline = outline_of(1)

      expect(outline.points).to eq([[0, 0], [100, 0], [0, 100]])
      expect(outline.end_points_of_contours).to eq([2])
      expect(outline.on_curve).to eq([true, true, true])
      expect(outline.advance_width).to eq(600)
      expect(outline.left_side_bearing).to eq(10)
      expect(outline.number_of_points).to eq(3)
      expect(outline.number_of_contours).to eq(1)
    end
  end

  describe 'compound glyph expansion' do
    it 'applies 2x2 rotation and point-to-point anchoring' do
      outline = outline_of(3)

      expect(outline.points).to eq([
        [500.0, 500.0], [600.0, 500.0],
        [500.0, 500.0], [500.0, 600.0], [400.0, 500.0],
      ])
      expect(outline.end_points_of_contours).to eq([1, 4])
      expect(outline.on_curve).to eq([true] * 5)
      expect(outline.advance_width).to eq(1000)
      expect(outline.left_side_bearing).to eq(50)
    end

    it 'applies negative scaling' do
      outline = outline_of(4)

      expect(outline.points).to eq([[0.0, 0.0], [-100.0, 0.0], [0.0, -100.0]])
    end

    it 'scales the component offset when flagged as scaled' do
      outline = outline_of(5)

      expect(outline.points).to eq([[15.0, 30.0], [165.0, 30.0], [15.0, 180.0]])
    end

    it 'keeps the component offset when flagged as unscaled' do
      outline = outline_of(6)

      expect(outline.points).to eq([[10.0, 20.0], [160.0, 20.0], [10.0, 170.0]])
    end

    it 'inherits metrics from the USE_MY_METRICS component' do
      outline = outline_of(7)

      expect(outline.advance_width).to eq(600)
      expect(outline.left_side_bearing).to eq(10)
    end

    it 'expands nested components' do
      outline = outline_of(8)

      expect(outline.points).to eq([
        [1000.0, 0.0], [900.0, 0.0], [1000.0, -100.0],
      ])
      expect(outline.advance_width).to eq(900)
    end

    it 'reports the glyph chain for self-recursion' do
      expect { outline_of(9) }.to raise_error(TTFunk::Error, /9 -> 9/)
    end

    it 'reports the glyph chain for mutual recursion' do
      expect { outline_of(10) }.to raise_error(TTFunk::Error, /10 -> 11 -> 10/)
    end

    it 'reports the glyph chain for an out of range parent anchor point' do
      expect { outline_of(12) }.to raise_error(TTFunk::Error, /anchor.*12/)
    end

    it 'reports the glyph chain for an out of range component anchor point' do
      expect { outline_of(13) }.to raise_error(TTFunk::Error, /anchor.*13/)
    end
  end

  describe 'recode' do
    it 'rewrites component glyph IDs without expanding the outline' do
      glyph = font.glyph_outlines.for(3)
      recoded = glyph.recode(2 => 20, 1 => 10)

      expect(recoded[12, 2].unpack1('n')).to eq(20)
      expect(recoded[20, 2].unpack1('n')).to eq(10)
      expect(glyph.glyph_ids).to eq([2, 1])
    end
  end
end
