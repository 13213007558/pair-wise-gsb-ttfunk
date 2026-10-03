# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk'

RSpec.describe TTFunk::Table::Glyf::QuadraticOutline do
  let(:path_class) { TTFunk::Table::Cff::Path }

  def cubic(points, parameter)
    points.map.with_index do |point, index|
      weight = [1, 3, 3, 1][index] *
        parameter**index * (1 - parameter)**(3 - index)
      Rational(weight, 1) * point
    end.sum
  end

  def quadratic(points, parameter)
    (1 - parameter)**2 * points[0] +
      2 * parameter * (1 - parameter) * points[1] +
      parameter**2 * points[2]
  end

  def cubic_controls(p0, p1, p2, p3, quadratic_points)
    q0, q1, q3 = quadratic_points
    [
      [p0[0] - q0[0], p0[1] - q0[1]],
      [
        p1[0] - (Rational(1, 3) * q0[0] + Rational(2, 3) * q1[0]),
        p1[1] - (Rational(1, 3) * q0[1] + Rational(2, 3) * q1[1]),
      ],
      [
        p2[0] - (Rational(2, 3) * q1[0] + Rational(1, 3) * q3[0]),
        p2[1] - (Rational(2, 3) * q1[1] + Rational(1, 3) * q3[1]),
      ],
      [p3[0] - q3[0], p3[1] - q3[1]],
    ]
  end

  def squared_error_bound(p0, p1, p2, p3, quadratic_points)
    controls = cubic_controls(p0, p1, p2, p3, quadratic_points)
    degree6_counts = [1, 6, 15, 20, 15, 6, 1]
    cubic_counts = [1, 3, 3, 1]

    (0..6).map do |degree|
      x_sum =
        bernstein_products(
          controls.map(&:first), degree, degree6_counts[degree], cubic_counts
        )
      y_sum =
        bernstein_products(
          controls.map(&:last), degree, degree6_counts[degree], cubic_counts
        )
      x_sum + y_sum
    end.max
  end

  def bernstein_products(values, degree, degree6_count, cubic_counts)
    (0..3).sum do |i|
      j = degree - i
      next 0 if j.negative? || j > 3

      Rational(cubic_counts[i] * cubic_counts[j], degree6_count) *
        values[i] * values[j]
    end
  end

  it 'converts an exactly representable cubic with one hand-checked quadratic' do
    p0 = [0r, 0r]
    p1 = [1r, 3r]
    p2 = [3r, 3r]
    p3 = [4r, 0r]

    segments = described_class.cubic_to_quadratic(p0, p1, p2, p3, 1, 0...1)

    expect(segments.length).to eq(1)
    expect(segments.first[:quadratic].map { |point| [point.x, point.y] })
      .to eq([[0r, 0r], [2r, 4r], [4r, 0r]])
    expect(segments[0][:interval]).to eq(0...1)
  end

  it 'subdivides a hand-checked symmetric curve and certifies every parameter' do
    p0 = [0r, 0r]
    p1 = [0r, 12r]
    p2 = [12r, 12r]
    p3 = [12r, 0r]
    tolerance = 1
    segments = described_class.cubic_to_quadratic(p0, p1, p2, p3, tolerance, 0...1)

    expect(segments.length).to eq(2)
    expect(segments.first[:interval].begin).to eq(0)
    expect(segments.last[:interval].end).to eq(1)
    expect(segments.each_cons(2).all? { |first, second|
      first[:interval].end == second[:interval].begin
    }).to eq(true)
    expect(segments.map { |segment| [segment[:quadratic][1].x, segment[:quadratic][1].y] })
      .to eq([[1r, 9r], [11r, 9r]])
    expect(segments.map { |segment| [segment[:quadratic][2].x, segment[:quadratic][2].y] })
      .to eq([[6r, 9r], [12r, 0r]])

    segments.each do |segment|
      a, b = segment[:interval].begin, segment[:interval].end
      original = segment[:cubic].map { |point| [point.x, point.y] }
      quadratic = segment[:quadratic].map { |point| [point.x, point.y] }
      bound = squared_error_bound(*original, quadratic)
      expect(bound).to be <= Rational(tolerance**2)

      101.times do |index|
        local = Rational(index, 100)
        expect(a + (b - a) * local).to be_between(0, 1)
        cubic_x = cubic(original.map(&:first), local)
        cubic_y = cubic(original.map(&:last), local)
        quad_x = quadratic(quadratic.map(&:first), local)
        quad_y = quadratic(quadratic.map(&:last), local)
        error = ((cubic_x - quad_x)**2 + (cubic_y - quad_y)**2)

        expect(error).to be <= bound
        expect(Math.sqrt(error.to_f)).to be <= tolerance
      end
    end
  end

  it 'includes integer quantization in the full parameter interval bound' do
    p0 = [0r, 0r]
    p1 = [0r, Rational(121, 10)]
    p2 = [Rational(121, 10), Rational(121, 10)]
    p3 = [Rational(121, 10), 0r]

    segments = described_class.cubic_to_quadratic(p0, p1, p2, p3, 2, 0...1)
    segments.each do |segment|
      quadratic = segment[:quadratic].map { |point| [point.x, point.y] }
      quadratic.flatten.each { |value| expect(value.denominator).to eq(1) }
      original = segment[:cubic].map { |point| [point.x, point.y] }
      bound = squared_error_bound(*original, quadratic)
      expect(Math.sqrt(bound.to_f)).to be <= 2
    end
  end

  it 'reports the reason when endpoint quantization cannot satisfy the tolerance' do
    path = path_class.new
    path.move_to(0, 0)
    path.line_to(Rational(1, 2), 0)
    path.close_path

    expect { described_class.from_path(path, Rational(1, 4)) }
      .to raise_error(TTFunk::Error, /quantization exceeds tolerance/)
  end

  it 'rejects non-positive and non-numeric tolerances before conversion' do
    expect { described_class.new(nil, 0) }
      .to raise_error(TTFunk::Error, /tolerance must be positive/)
    expect { described_class.new(nil, false) }
      .to raise_error(TTFunk::Error, /tolerance must be a positive number/)
  end

  it 'handles closed contours, repeated controls, degenerate segments and empty glyphs' do
    path = path_class.new
    path.move_to(0, 0)
    path.curve_to(0, 4, 4, 4, 4, 0)
    path.curve_to(4, -4, 8, -4, 8, 0)
    path.line_to(10, 0)
    path.line_to(10, 0)
    path.curve_to(10, 10, 10, 10, 10, 10)
    path.line_to(0, 10)
    path.line_to(0, 0)
    path.close_path

    outline = described_class.from_path(path, 1)

    expect(outline.number_of_contours).to eq(1)
    expect(outline.contours[0].points.first).to have_attributes(x: 0, y: 0, on_curve: true)
    expect(outline.contours[0].points.last).to have_attributes(x: 0, y: 10, on_curve: true)
    expect(outline.recode).to start_with([1, 0, -3, 10, 10].pack('n5'))

    expect(described_class.from_path(path_class.new, 1).recode).to eq('')
  end

  it 'round-trips an encoded glyph through the glyf parser without instructions' do
    path = path_class.new
    path.move_to(0, 0)
    path.curve_to(0, 12, 12, 12, 12, 0)
    path.close_path
    outline = described_class.from_path(path, 1)
    parsed = TTFunk::Table::Glyf::Simple.new(0, outline.recode)

    expect(parsed.number_of_contours).to eq(1)
    expect(parsed.instruction_length).to eq(0)
    expect(parsed.points.length).to eq(outline.end_point_of_last_contour)
    expect(parsed.points.map { |point| [point[:x], point[:y], point[:on_curve]] })
      .to eq(outline.contours[0].points.map { |point| [point.x, point.y, point.on_curve] })
  end

  it 'reports when a glyph exceeds the TrueType point limit' do
    path = path_class.new
    path.move_to(0, 0)
    65_536.times { |index| path.line_to(0, index.even? ? 1 : 0) }

    expect { described_class.from_path(path, 1) }
      .to raise_error(TTFunk::Error, /TrueType point limit/)
  end
end
