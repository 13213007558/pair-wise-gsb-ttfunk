# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cff/path'
require 'ttfunk/table/glyf/path_based'

RSpec.describe TTFunk::Table::Glyf::TrueTypePathEncoder do
  let(:metric) do
    TTFunk::Table::Hmtx::HorizontalMetric.new(600, 0)
  end

  def path_with(*commands)
    TTFunk::Table::Cff::Path.new.tap do |path|
      commands.each { |command| path.public_send(*command) }
    end
  end

  def glyph_for(path, tolerance = 2)
    TTFunk::Table::Glyf::PathBased.new(path, metric, tolerance)
  end

  it 'bounds hand-computed quadratic halves over the complete interval' do
    curve = [[0, 0], [0, 36], [48, 84], [48, 48]]
    control = Rational(3 * 0 + 3 * 48 - 0 - 48, 4), Rational(3 * 36 + 3 * 84 - 0 - 48, 4)

    expect(control).to eq([Rational(24), Rational(78)])
    expect(
      described_class.continuous_error_squared(curve),
    ).to eq(Rational(2, 3))

    maximum_error = Math.sqrt(2.0 / 3.0)
    expect(maximum_error).to be_within(1e-12).of(Math.sqrt(Rational(2, 3)))
  end

  it 'checks exact critical parameter values as well as both endpoints' do
    half_curve = [
      [0, 0],
      [0, 18],
      [12, 51],
      [24, 51],
    ].map { |x, y| [Rational(x), Rational(y)] }
    critical_values = [
      0.0,
      1.0,
      (3 - Math.sqrt(3.0)) / 6,
      (3 + Math.sqrt(3.0)) / 6,
    ]
    squared_scalar_at = ->(t) { (3 * t * (1 - t) * (1 - (2 * t)))**2 }

    exact_maximum = 68.0 * critical_values.map { |t|
      squared_scalar_at.call(t)
    }.max

    expect(
      described_class.single_quadratic_error_squared(half_curve),
    ).to eq(Rational(17, 3))
    expect(
      described_class.single_quadratic_error_squared(half_curve).to_f,
    ).to be_within(1e-12).of(exact_maximum)
  end

  it 'subdivides when continuous error alone exceeds the tolerance' do
    path = path_with(
      [:move_to, 0, 0],
      [:curve_to, 0, 60, 100, 120, 100, 0],
      [:close_path],
    )

    encoding = described_class.encode(path, 2)

    expect(encoding[:points].count(&:on_curve)).to eq(2)
    expect(encoding[:points].reject(&:on_curve).length).to eq(4)
    expect(encoding[:number_of_contours]).to eq(1)
  end

  it 'refuses quantization that would consume the complete tolerance' do
    path = path_with(
      [:move_to, 0, 0],
      [:line_to, Rational(1, 2), Rational(1, 2)],
      [:close_path],
    )

    expect {
      described_class.encode(path, Rational(1, 2))
    }.to raise_error(
      TTFunk::Table::Glyf::PathBased::ConversionError,
      /cannot be quantized within 1\/2 font units/,
    )
  end

  it 'uses adjacent control points for the implicit on-curve point at a subdivision' do
    path = path_with(
      [:move_to, 0, 0],
      [:curve_to, 0, 60, 100, 120, 100, 0],
      [:close_path],
    )

    encoding = described_class.encode(path, 10)
    point_flags = encoding[:points].map { |point| point.on_curve ? 1 : 0 }

    expect(point_flags.each_cons(2)).to include([0, 0])
  end

  it 'encodes degenerate line segments and an explicitly closed contour' do
    path = path_with(
      [:move_to, 10, 12],
      [:line_to, 10, 12],
      [:line_to, 20, 12],
      [:line_to, 10, 12],
      [:close_path],
    )

    encoding = described_class.encode(path, 2)

    expect(encoding[:number_of_contours]).to eq(1)
    expect(encoding[:points].map { |point| [point.x, point.y, point.on_curve ? 1 : 0] }).to eq(
      [[10, 12, 1], [10, 12, 1], [20, 12, 1], [10, 12, 1]],
    )
    expect(encoding[:x_min]).to eq(10)
    expect(encoding[:y_min]).to eq(12)
    expect(encoding[:x_max]).to eq(20)
    expect(encoding[:y_max]).to eq(12)
  end

  it 'encodes a move-only empty glyph as zero glyph data' do
    path = path_with([:move_to, 20, 30], [:close_path])

    encoding = described_class.encode(path, 2)

    expect(encoding[:raw]).to be_empty
    expect(encoding[:number_of_contours]).to eq(0)
    expect(encoding[:end_points_of_contours]).to be_empty
  end

  it 'writes no instructions for converted outlines' do
    glyph = glyph_for(
      path_with(
        [:move_to, 0, 0],
        [:line_to, 10, 0],
        [:line_to, 10, 10],
        [:close_path],
      ),
      2,
    )

    offset = 10 + (2 * glyph.number_of_contours)
    expect(glyph.recode[offset, 2].unpack1('n')).to eq(0)
    expect(glyph.instruction_length).to eq(0)
    expect(glyph.instructions).to be_empty
  end
end
