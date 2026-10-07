# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/glyf'

RSpec.describe TTFunk::Table::Glyf::CubicToQuadratic do
  def close_path_with(path, *cubic)
    path.move_to(0, 0)
    path.curve_to(*cubic)
    path.close_path
    path
  end

  def cubic_point(controls, t)
    (1 - t).then do |inverse|
      controls[0] * inverse**3 +
        controls[1] * (3 * inverse**2 * t) +
        controls[2] * (3 * inverse * t**2) +
        controls[3] * t**3
    end
  end

  def quadratic_point(start, control, endpoint, t)
    inverse = 1 - t
    start * inverse**2 + control * (2 * inverse * t) + endpoint * t**2
  end

  def local_parameter(segment, global_t)
    range = segment.t_range
    (global_t - range.begin) / (range.end - range.begin)
  end

  it 'converts a closed rectangular line path to integer on-curve points' do
    path = TTFunk::Table::Cff::Path.new
    path.move_to(0, 0)
    path.line_to(10, 0)
    path.line_to(10, 10)
    path.line_to(0, 10)
    path.close_path

    result = described_class.convert(path, max_error: 0)

    expect(result.contours.count).to eq(1)
    expect(result.max_error).to eq(0)
    expect(result.contours.first.map(&:type)).to all(eq(:line))
  end

  it 'builds an encoded simple TrueType glyph directly from a path' do
    path = TTFunk::Table::Cff::Path.new
    path.move_to(0, 0)
    path.line_to(10, 0)
    path.line_to(10, 10)
    path.line_to(0, 10)
    path.close_path

    glyph = TTFunk::Table::Glyf::SimpleOutline.from_path(path, max_error: 0)

    expect(glyph).to be_a(TTFunk::Table::Glyf::SimpleOutline)
    expect(glyph.number_of_contours).to eq(1)
    expect(glyph.recode(nil).bytesize).to be_positive
  end

  it 'approximates a cubic curve within the requested tolerance' do
    point_class = described_class::Point
    cubic_controls = [
      point_class.new(0, 0),
      point_class.new(0, 100),
      point_class.new(100, 100),
      point_class.new(100, 0),
    ]
    path = close_path_with(TTFunk::Table::Cff::Path.new, 0, 100, 100, 100, 100, 0)

    result = described_class.convert(path, max_error: 1.0)
    curve_segments = result.contours.first.select { |segment| segment.type == :curve }

    expect(curve_segments).not_to be_empty
    expect(result.max_error).to be <= 1.0

    curve_segments.each do |segment|
      start = segment.source.first
      control = segment.points.first
      endpoint = segment.points.last

      11.times do |index|
        global_t =
          segment.t_range.begin +
            (index / 10.0) * (segment.t_range.end - segment.t_range.begin)
        t = local_parameter(segment, global_t)
        expected = cubic_point(cubic_controls, global_t)
        actual = quadratic_point(start, control, endpoint, t)
        distance = Math.sqrt((expected.x - actual.x)**2 + (expected.y - actual.y)**2)

        expect(distance).to be <= result.max_error + 1e-9
      end
    end
  end

  it 'treats a degenerate cubic curve as a line' do
    path = TTFunk::Table::Cff::Path.new
    path.move_to(0, 0)
    path.curve_to(0, 0, 100, 100, 100, 100)
    path.close_path

    result = described_class.convert(path, max_error: 0)

    expect(result.contours.first.map(&:type)).to all(eq(:line))
  end

  it 'handles a cusp with bounded adaptive subdivision' do
    path = TTFunk::Table::Cff::Path.new
    path.move_to(0, 0)
    path.curve_to(100, 100, 0, 100, 100, 0)
    path.close_path

    result = described_class.convert(path, max_error: 1.0, max_segments: 16)
    segments = result.contours.first.select { |segment| segment.type == :curve }

    expect(segments.count).to be_between(2, 16)
    expect(result.max_error).to be <= 1.0
  end

  it 'raises when integer rounding by itself exceeds tolerance' do
    path = TTFunk::Table::Cff::Path.new
    path.move_to(0.4, 0)
    path.line_to(10.4, 0)
    path.close_path

    expect { described_class.convert(path, max_error: 0.3) }
      .to raise_error(ArgumentError, /exceeds the requested tolerance/)
  end

  it 'raises rather than exceeding the subdivision budget' do
    path = TTFunk::Table::Cff::Path.new
    path.move_to(0, 0)
    path.curve_to(0, 1000, 1000, -1000, 1000, 0)
    path.close_path

    expect { described_class.convert(path, max_error: 0.1, max_segments: 2) }
      .to raise_error(ArgumentError, /more than 2 segments/)
  end
end
