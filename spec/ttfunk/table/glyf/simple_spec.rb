# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/glyf/simple'
require 'ttfunk/table/hmtx'

RSpec.describe TTFunk::Table::Glyf::Simple do
  # Builds raw data for a simple glyph. Contours are arrays of
  # [x, y, on_curve] points.
  def build_simple_glyph(contours)
    points = contours.flatten(1)
    xs = points.map(&:first)
    ys = points.map { |point| point[1] }

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
    raw << points.map { |point| point[2] ? 1 : 0 }.pack('C*')

    previous = 0
    raw << xs.map { |x| delta = x - previous; previous = x; delta }.pack('s>*')
    previous = 0
    raw << ys.map { |y| delta = y - previous; previous = y; delta }.pack('s>*')

    raw
  end

  let(:hmtx_table) do
    table = instance_double(TTFunk::Table::Hmtx)
    allow(table).to receive(:for) { |id|
      TTFunk::Table::Hmtx::HorizontalMetric.new(1000 + id, id)
    }
    table
  end

  describe '#points' do
    it 'parses coordinates and on-curve flags' do
      glyph = described_class.new(
        5,
        build_simple_glyph(
          [
            [[0, 0, true], [100, 0, false], [100, 100, true]],
            [[-50, 250, true]],
          ],
        ),
      )

      expect(glyph.points).to eq [
        TTFunk::Table::Glyf::OutlinePoint.new(0, 0, true),
        TTFunk::Table::Glyf::OutlinePoint.new(100, 0, false),
        TTFunk::Table::Glyf::OutlinePoint.new(100, 100, true),
        TTFunk::Table::Glyf::OutlinePoint.new(-50, 250, true),
      ]
      expect(glyph.end_points_of_contours).to eq [2, 3]
    end
  end

  describe '#decompose' do
    it 'returns its own outline and horizontal metrics' do
      glyph = described_class.new(
        5,
        build_simple_glyph([[[10, 20, true], [30, 40, false]]]),
      )

      outline = glyph.decompose(nil, hmtx_table)

      expect(outline.points).to eq glyph.points
      expect(outline.end_points_of_contours).to eq [1]
      expect(outline.horizontal_metrics.advance_width).to eq 1005
      expect(outline.horizontal_metrics.left_side_bearing).to eq 5
    end
  end
end
