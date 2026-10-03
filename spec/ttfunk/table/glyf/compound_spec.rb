# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/glyf/compound'
require 'ttfunk/table/glyf/simple'
require 'ttfunk/table/glyf'
require 'ttfunk/table/hmtx'

RSpec.describe TTFunk::Table::Glyf::Compound do
  let(:point) { TTFunk::Table::Glyf::OutlinePoint }
  let(:xy_words) do
    described_class::ARGS_ARE_XY_VALUES |
      described_class::ARG_1_AND_2_ARE_WORDS
  end

  # Builds raw data for a simple glyph. Contours are arrays of
  # [x, y, on_curve] points.
  def build_simple_glyph(contours)
    points = contours.flatten(1)
    xs = points.map(&:first)
    ys = points.map { |p| p[1] }

    end_points = []
    point_count = 0
    contours.each do |contour|
      point_count += contour.length
      end_points << (point_count - 1)
    end

    raw = [
      contours.length,
      xs.min || 0, ys.min || 0, xs.max || 0, ys.max || 0,
    ].pack('s>*')
    raw << end_points.pack('n*')
    raw << [0].pack('n') # instruction length
    raw << points.map { |p| p[2] ? 1 : 0 }.pack('C*')

    previous = 0
    raw << xs.map { |x| delta = x - previous; previous = x; delta }.pack('s>*')
    previous = 0
    raw << ys.map { |y| delta = y - previous; previous = y; delta }.pack('s>*')

    raw
  end

  # Builds raw data for a compound glyph. Each component is a hash with
  # :flags, :glyph_id, :arg1, :arg2, and optionally :transform.
  def build_compound_glyph(components)
    raw = [-1, 0, 0, 0, 0].pack('s>*')

    components.each_with_index do |component, index|
      flags = component[:flags]
      flags |= described_class::MORE_COMPONENTS if index < components.length - 1

      raw << [flags, component[:glyph_id]].pack('n*')
      raw <<
        if flags.anybits?(described_class::ARG_1_AND_2_ARE_WORDS)
          [component[:arg1], component[:arg2]].pack('s>*')
        else
          [component[:arg1], component[:arg2]].pack('c*')
        end

      transform = component[:transform]
      if flags.anybits?(described_class::WE_HAVE_A_TWO_BY_TWO)
        raw << transform.map { |v| (v * 0x4000).round }.pack('s>*')
      elsif flags.anybits?(described_class::WE_HAVE_AN_X_AND_Y_SCALE)
        raw << transform.map { |v| (v * 0x4000).round }.pack('s>*')
      elsif flags.anybits?(described_class::WE_HAVE_A_SCALE)
        raw << [(transform * 0x4000).round].pack('s>')
      end
    end

    raw
  end

  def simple_glyph(id, contours)
    TTFunk::Table::Glyf::Simple.new(id, build_simple_glyph(contours))
  end

  def compound_glyph(id, components)
    described_class.new(id, build_compound_glyph(components))
  end

  def expand(glyphs, glyph_id)
    glyf_table = instance_double(TTFunk::Table::Glyf)
    allow(glyf_table).to receive(:for) { |id| glyphs[id] }

    hmtx_table = instance_double(TTFunk::Table::Hmtx)
    allow(hmtx_table).to receive(:for) { |id|
      TTFunk::Table::Hmtx::HorizontalMetric.new(1000 + id, id)
    }

    glyphs[glyph_id].decompose(glyf_table, hmtx_table)
  end

  describe '#decompose' do
    it 'offsets components by their x/y displacement' do
      glyphs = {
        1 => simple_glyph(1, [[[0, 0, true], [10, 0, true], [10, 10, false]]]),
        2 => compound_glyph(
          2,
          [
            { flags: xy_words, glyph_id: 1, arg1: 100, arg2: 200 },
            {
              flags: described_class::ARGS_ARE_XY_VALUES,
              glyph_id: 1, arg1: -50, arg2: 0,
            },
          ],
        ),
      }

      outline = expand(glyphs, 2)

      expect(outline.points).to eq [
        point.new(100, 200, true),
        point.new(110, 200, true),
        point.new(110, 210, false),
        point.new(-50, 0, true),
        point.new(-40, 0, true),
        point.new(-40, 10, false),
      ]
      expect(outline.end_points_of_contours).to eq [2, 5]
    end

    it 'expands nested components' do
      glyphs = {
        1 => simple_glyph(1, [[[1, 2, true]]]),
        2 => compound_glyph(
          2,
          [{ flags: xy_words, glyph_id: 1, arg1: 10, arg2: 20 }],
        ),
        3 => compound_glyph(
          3,
          [{ flags: xy_words, glyph_id: 2, arg1: 100, arg2: 200 }],
        ),
      }

      outline = expand(glyphs, 3)

      expect(outline.points).to eq [point.new(111, 222, true)]
      expect(outline.end_points_of_contours).to eq [0]
    end

    it 'anchors transformed components to parent points' do
      glyphs = {
        1 => simple_glyph(1, [[[100, 200, true], [300, 400, true]]]),
        4 => simple_glyph(4, [[[10, 0, true], [0, 10, true]]]),
        5 => compound_glyph(
          5,
          [
            { flags: xy_words, glyph_id: 1, arg1: 0, arg2: 0 },
            {
              flags: described_class::ARG_1_AND_2_ARE_WORDS |
                described_class::WE_HAVE_A_TWO_BY_TWO,
              glyph_id: 4,
              arg1: 1,
              arg2: 0,
              # 90 degree counter-clockwise rotation
              transform: [0, 1, -1, 0],
            },
          ],
        ),
      }

      outline = expand(glyphs, 5)

      # component points rotate to (0, 10) and (-10, 0); anchoring parent
      # point 1 (300, 400) to component point 0 (0, 10) shifts the
      # component by (300, 390)
      expect(outline.points).to eq [
        point.new(100, 200, true),
        point.new(300, 400, true),
        point.new(300, 400, true),
        point.new(290, 390, true),
      ]
      expect(outline.end_points_of_contours).to eq [1, 3]
    end

    it 'applies negative scale to component points' do
      glyphs = {
        1 => simple_glyph(1, [[[100, 200, true], [300, 400, true]]]),
        6 => compound_glyph(
          6,
          [
            {
              flags: xy_words | described_class::WE_HAVE_A_SCALE,
              glyph_id: 1, arg1: 0, arg2: 0, transform: -1,
            },
          ],
        ),
        7 => compound_glyph(
          7,
          [
            {
              flags: xy_words | described_class::WE_HAVE_AN_X_AND_Y_SCALE,
              glyph_id: 1, arg1: 0, arg2: 0, transform: [-1, 1],
            },
          ],
        ),
      }

      expect(expand(glyphs, 6).points).to eq [
        point.new(-100, -200, true),
        point.new(-300, -400, true),
      ]
      expect(expand(glyphs, 7).points).to eq [
        point.new(-100, 200, true),
        point.new(-300, 400, true),
      ]
    end

    it 'inherits horizontal metrics from USE_MY_METRICS component' do
      glyphs = {
        1 => simple_glyph(1, [[[0, 0, true]]]),
        8 => compound_glyph(
          8,
          [
            {
              flags: xy_words | described_class::USE_MY_METRICS,
              glyph_id: 1, arg1: 0, arg2: 0,
            },
          ],
        ),
        9 => compound_glyph(
          9,
          [{ flags: xy_words, glyph_id: 1, arg1: 0, arg2: 0 }],
        ),
      }

      inherited = expand(glyphs, 8).horizontal_metrics
      expect(inherited.advance_width).to eq 1001
      expect(inherited.left_side_bearing).to eq 1

      own = expand(glyphs, 9).horizontal_metrics
      expect(own.advance_width).to eq 1009
      expect(own.left_side_bearing).to eq 9
    end

    it 'scales component offset only when flagged' do
      glyphs = {
        1 => simple_glyph(1, [[[1, 1, true]]]),
        10 => compound_glyph(
          10,
          [
            {
              flags: xy_words | described_class::WE_HAVE_A_SCALE |
                described_class::SCALED_COMPONENT_OFFSET,
              glyph_id: 1, arg1: 10, arg2: 20, transform: 0.5,
            },
          ],
        ),
        11 => compound_glyph(
          11,
          [
            {
              flags: xy_words | described_class::WE_HAVE_A_SCALE |
                described_class::UNSCALED_COMPONENT_OFFSET,
              glyph_id: 1, arg1: 10, arg2: 20, transform: 0.5,
            },
          ],
        ),
        12 => compound_glyph(
          12,
          [
            {
              flags: xy_words | described_class::WE_HAVE_A_SCALE,
              glyph_id: 1, arg1: 10, arg2: 20, transform: 0.5,
            },
          ],
        ),
      }

      expect(expand(glyphs, 10).points).to eq [point.new(5.5, 10.5, true)]
      expect(expand(glyphs, 11).points).to eq [point.new(10.5, 20.5, true)]
      expect(expand(glyphs, 12).points).to eq [point.new(10.5, 20.5, true)]
    end

    it 'reports glyph chain for circular component references' do
      glyphs = {
        1 => compound_glyph(
          1,
          [{ flags: xy_words, glyph_id: 2, arg1: 0, arg2: 0 }],
        ),
        2 => compound_glyph(
          2,
          [{ flags: xy_words, glyph_id: 1, arg1: 0, arg2: 0 }],
        ),
        3 => compound_glyph(
          3,
          [{ flags: xy_words, glyph_id: 3, arg1: 0, arg2: 0 }],
        ),
      }

      expect { expand(glyphs, 1) }.to raise_error(
        TTFunk::Error,
        /circular component reference.*1 -> 2 -> 1/,
      )
      expect { expand(glyphs, 3) }.to raise_error(
        TTFunk::Error,
        /circular component reference.*3 -> 3/,
      )
    end

    it 'reports glyph chain for out of range anchor points' do
      glyphs = {
        1 => simple_glyph(1, [[[100, 200, true], [300, 400, true]]]),
        4 => compound_glyph(
          4,
          [
            { flags: xy_words, glyph_id: 1, arg1: 0, arg2: 0 },
            {
              flags: described_class::ARG_1_AND_2_ARE_WORDS,
              glyph_id: 1, arg1: 5, arg2: 0,
            },
          ],
        ),
        5 => compound_glyph(
          5,
          [
            { flags: xy_words, glyph_id: 1, arg1: 0, arg2: 0 },
            {
              flags: described_class::ARG_1_AND_2_ARE_WORDS,
              glyph_id: 1, arg1: 0, arg2: 9,
            },
          ],
        ),
      }

      expect { expand(glyphs, 4) }.to raise_error(
        TTFunk::Error,
        /anchor point 5 not found in compound glyph 4 .*glyph chain: 4/,
      )
      expect { expand(glyphs, 5) }.to raise_error(
        TTFunk::Error,
        /anchor point 9 not found in component glyph 1 .*glyph chain: 5 -> 1/,
      )
    end
  end

  describe '#recode' do
    it 'rewrites component glyph IDs without expanding outlines' do
      glyph = compound_glyph(
        2,
        [
          { flags: xy_words, glyph_id: 1, arg1: 100, arg2: 200 },
          { flags: xy_words, glyph_id: 4, arg1: -50, arg2: 0 },
        ],
      )

      recoded = described_class.new(2, glyph.recode(1 => 7, 4 => 9))

      expect(recoded.glyph_ids).to eq [7, 9]
      expect(recoded.raw.length).to eq glyph.raw.length
    end
  end
end
