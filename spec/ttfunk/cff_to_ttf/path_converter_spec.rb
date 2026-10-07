# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::CffToTtf::PathConverter do
  let(:converter) { described_class.new(max_error: max_error) }
  let(:max_error) { 1.0 }

  def build_path(&block)
    TTFunk::Table::Cff::Path.new.tap do |path|
      path.instance_exec(path, &block)
    end
  end

  def deviation_for(path, result)
    outline_deviation(
      sample_cff_path(path),
      sample_quadratic_contours(result.contours),
    )
  end

  it 'converts an empty path' do
    result = converter.convert(TTFunk::Table::Cff::Path.new)

    expect(result).to be_complete
    expect(result.contours).to eq([])
  end

  it 'converts straight line contours keeping only on-curve points' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.line_to(100, 0)
      p.line_to(100, 100)
      p.line_to(0, 100)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours).to eq([
      [[0, 0, true], [100, 0, true], [100, 100, true], [0, 100, true]],
    ])
  end

  it 'drops a closing point that duplicates the contour start' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.line_to(50, 0)
      p.line_to(0, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result.contours).to eq([[[0, 0, true], [50, 0, true]]])
  end

  it 'closes the current contour when a new one starts' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.line_to(10, 0)
      p.move_to(20, 20)
      p.line_to(30, 20)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours.length).to eq(2)
  end

  it 'approximates a gentle cubic with a single quadratic segment' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.curve_to(33, 10, 67, 10, 100, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours).to eq([
      [[0, 0, true], [50, 15, false], [100, 0, true]],
    ])
  end

  it 'subdivides a steep cubic into multiple quadratic segments' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.curve_to(0, 100, 100, 100, 100, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    contour = result.contours.first
    # 4 quadratic segments: 1 move + 4 * (off-curve, on-curve)
    expect(contour.length).to eq(9)
    expect(contour.map(&:last)).to eq(
      [true, false, true, false, true, false, true, false, true],
    )
    expect(deviation_for(path, result)).to be <= max_error
  end

  it 'limits subdivision to the given depth' do
    converter = described_class.new(max_error: 2.0, max_depth: 1)
    path = build_path do |p|
      p.move_to(0, 0)
      p.curve_to(0, 100, 100, 100, 100, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours.first.length).to eq(5)
    expect(deviation_for(path, result)).to be <= 2.0
  end

  it 'collapses a degenerate cubic that is a straight line' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.curve_to(10, 0, 20, 0, 30, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours).to eq([[[0, 0, true], [30, 0, true]]])
  end

  it 'does not collapse a backtracking collinear cubic' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.curve_to(30, 0, -10, 0, 10, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours.first.length).to be > 2
    expect(deviation_for(path, result)).to be <= max_error
  end

  it 'handles cusps' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.curve_to(100, 100, -100, 100, 0, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(deviation_for(path, result)).to be <= max_error
  end

  it 'skips zero-length curves' do
    path = build_path do |p|
      p.move_to(5, 5)
      p.curve_to(5, 5, 5, 5, 5, 5)
      p.line_to(10, 10)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours).to eq([[[5, 5, true], [10, 10, true]]])
  end

  it 'rounds coordinates to integers keeping the error within budget' do
    path = build_path do |p|
      p.move_to(0.25, 0.5)
      p.curve_to(10.5, 40.75, 90.5, 40.25, 100.75, 0.5)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    result.contours.each do |contour|
      contour.each do |x, y, _on_curve|
        expect(x).to be_an(Integer)
        expect(y).to be_an(Integer)
      end
    end
    expect(deviation_for(path, result)).to be <= max_error
  end

  it 'preserves the number of contours' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.line_to(10, 0)
      p.line_to(10, 10)
      p.close_path
      p.move_to(20, 20)
      p.curve_to(30, 30, 40, 30, 50, 20)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).to be_complete
    expect(result.contours.length).to eq(2)
  end

  context 'when the error budget is smaller than the rounding reserve' do
    let(:max_error) { 0.5 }

    it 'reports the conversion as incomplete' do
      path = build_path do |p|
        p.move_to(0, 0)
        p.curve_to(33, 10, 67, 10, 100, 0)
        p.close_path
      end

      result = converter.convert(path)

      expect(result).not_to be_complete
    end

    it 'still converts straight lines' do
      path = build_path do |p|
        p.move_to(0, 0)
        p.line_to(100, 0)
        p.close_path
      end

      result = converter.convert(path)

      expect(result).to be_complete
    end
  end

  it 'reports coordinates outside the glyf range as incomplete' do
    path = build_path do |p|
      p.move_to(0, 0)
      p.line_to(40_000, 0)
      p.close_path
    end

    result = converter.convert(path)

    expect(result).not_to be_complete
  end

  context 'when the subdivision depth is exhausted' do
    it 'reports the conversion as incomplete' do
      converter = described_class.new(max_error: 1.0, max_depth: 1)
      path = build_path do |p|
        p.move_to(0, 0)
        p.curve_to(0, 100, 100, 100, 100, 0)
        p.close_path
      end

      result = converter.convert(path)

      expect(result).not_to be_complete
    end
  end
end
