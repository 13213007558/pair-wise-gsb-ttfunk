# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::OutlineInspector do
  let(:inspector) { described_class.new }

  def on(x, y)
    [x, y, true]
  end

  def off(x, y)
    [x, y, false]
  end

  # Signed area of the polygon through the given points (the "control
  # polygon" a naive checker would use).
  def polygon_area(points)
    sum = 0
    points.each_with_index do |point, index|
      nxt = points[(index + 1) % points.length]
      sum += (point[0] * nxt[1]) - (nxt[0] * point[1])
    end
    sum / 2.0
  end

  describe 'signed area' do
    it 'integrates the curve analytically, not the control polygon' do
      # A "lens": one quadratic arc plus its closing chord.
      report = inspector.inspect_contours(
        [[on(0, 0), off(50, 100), on(100, 0)]],
        glyph_id: 7,
      )
      expect(report.contours.length).to eq(1)
      contour = report.contours.first
      # True area under the arc is 2/3 of the control triangle.
      expect(contour.signed_area).to be_within(1e-9).of(-10_000.0 / 3)
      expect(contour.direction).to eq(:clockwise)
      expect(report.issues).to be_empty
    end

    it 'expands implied on-curve points between off-curve points' do
      report = inspector.inspect_contours(
        [[on(0, 0), off(50, 100), off(100, 0), off(150, 100), on(200, 0)]],
      )
      # Three arcs (two implied midpoints) plus the closing line.
      expect(report.contours.first.segment_count).to eq(4)
    end
  end

  describe 'tangent hole' do
    # A hole whose top arc rises to touch the outer contour exactly at
    # (100, 200) with a horizontal tangent on both sides.
    let(:contours) do
      [
        [on(0, 0), on(0, 200), on(200, 200), on(200, 0)],
        [on(60, 160), on(100, 110), on(140, 160), off(100, 240)],
      ]
    end

    it 'reports nesting and the tangent contact with curve parameters' do
      report = inspector.inspect_contours(contours, glyph_id: 3)
      outer, hole = report.contours
      expect(outer.role).to eq(:outer)
      expect(outer.direction).to eq(:clockwise)
      expect(outer.depth).to eq(0)
      expect(hole.role).to eq(:hole)
      expect(hole.direction).to eq(:counterclockwise)
      expect(hole.depth).to eq(1)
      expect(hole.signed_area).to be_within(1e-9).of(12_400.0 / 3)
      expect(report.issues.length).to eq(1)
      issue = report.issues.first
      expect(issue.type).to eq(:tangent_contact)
      expect(issue.point[0]).to be_within(1e-6).of(100)
      expect(issue.point[1]).to be_within(1e-6).of(200)
      expect(issue.locations).to contain_exactly(
        { contour: 0, segment: 1, t: be_within(1e-6).of(0.5) },
        { contour: 1, segment: 2, t: be_within(1e-6).of(0.5) },
      )
    end

    it 'does not mistake the tangency for a crossing' do
      report = inspector.inspect_contours(contours)
      types = report.issues.map(&:type)
      expect(types).not_to include(:contour_intersection)
      expect(types).not_to include(:self_intersection)
    end
  end

  describe 'misleading control polygon' do
    # The control polygon of this contour runs counterclockwise
    # (shoelace area +60) and crosses itself twice, while the actual
    # curve is a simple clockwise contour of area -4720/3. A checker
    # that connects control points into a polyline gets both the
    # orientation and the self-intersection verdict wrong.
    let(:contour) do
      [
        on(0, 0), off(50, -98), on(100, 0),
        on(100, -50), on(96, -50), on(96, -30), on(88, -30), on(88, -50),
        on(0, -50),
      ]
    end

    it 'takes the direction from the curve, not the control polygon' do
      # Sanity check: the trap is set - the control polygon really is
      # misleading.
      expect(polygon_area(contour)).to be_positive
      report = inspector.inspect_contours([contour], glyph_id: 11)
      contour_report = report.contours.first
      expect(contour_report.signed_area).to be_within(1e-9).of(-4720.0 / 3)
      expect(contour_report.direction).to eq(:clockwise)
      expect(contour_report.role).to eq(:outer)
    end

    it 'finds no self-intersection although the control polygon crosses itself' do
      report = inspector.inspect_contours([contour])
      expect(report.issues).to be_empty
    end
  end

  describe 'self-intersection' do
    it 'reports the crossing of a bowtie contour' do
      report = inspector.inspect_contours(
        [[on(0, 0), on(100, 100), on(100, 0), on(0, 100)]],
        glyph_id: 5,
      )
      expect(report.issues.length).to eq(1)
      issue = report.issues.first
      expect(issue.type).to eq(:self_intersection)
      expect(issue.point[0]).to be_within(1e-6).of(50)
      expect(issue.point[1]).to be_within(1e-6).of(50)
      expect(issue.locations).to contain_exactly(
        { contour: 0, segment: 0, t: be_within(1e-6).of(0.5) },
        { contour: 0, segment: 2, t: be_within(1e-6).of(0.5) },
      )
    end
  end

  describe 'overlapping edges' do
    it 'reports coincident edges shared by two contours' do
      report = inspector.inspect_contours(
        [
          [on(0, 0), on(0, 100), on(100, 100), on(100, 0)],
          [on(100, 0), on(100, 100), on(200, 100), on(200, 0)],
        ],
      )
      overlap = report.issues.find { |issue| issue.type == :overlapping_edges }
      expect(overlap).not_to be_nil
      expect(overlap.locations.length).to eq(2)
      expect(overlap.locations[0][:contour]).to eq(0)
      expect(overlap.locations[0][:segment]).to eq(2)
      expect(overlap.locations[1][:contour]).to eq(1)
      expect(overlap.locations[1][:segment]).to eq(0)
      expect(overlap.locations[0][:t]).to be_a(Range)
    end

    it 'reports a contour doubling back on itself' do
      report = inspector.inspect_contours(
        [[on(0, 0), on(100, 0), on(200, 0), on(100, 0), on(100, 100), on(0, 100)]],
      )
      overlap = report.issues.find { |issue| issue.type == :overlapping_edges }
      expect(overlap).not_to be_nil
      expect(overlap.locations.map { |loc| loc[:segment] }).to contain_exactly(1, 2)
    end
  end

  describe 'orientation mismatch' do
    it 'flags an outer contour running against the TrueType convention' do
      # Counterclockwise square: right shape, wrong direction.
      report = inspector.inspect_contours(
        [[on(0, 0), on(100, 0), on(100, 100), on(0, 100)]],
      )
      expect(report.contours.first.direction).to eq(:counterclockwise)
      expect(report.issues.map(&:type)).to eq([:orientation_mismatch])
    end
  end

  describe 'report' do
    it 'summarizes glyph, contours, and issues' do
      report = inspector.inspect_contours(
        [[on(0, 0), on(100, 100), on(100, 0), on(0, 100)]],
        glyph_id: 42,
      )
      text = report.to_s
      expect(text).to include('glyph 42')
      expect(text).to include('contour 0')
      expect(text).to include('self_intersection')
      expect(report).not_to be_ok
    end
  end

  describe 'font integration' do
    let(:file) { TTFunk::File.open(test_font(:DejaVuSans)) }
    let(:inspector) { described_class.new(file) }

    it 'inspects a simple glyph with a hole' do
      glyph_id = file.cmap.unicode.first[0x41] # 'A'
      report = inspector.inspect_glyph(glyph_id)
      expect(report).to be_supported
      expect(report.contours.length).to eq(2)
      # DejaVu stores the inner triangle of 'A' as contour 0.
      expect(report.contours.map(&:role)).to eq(%i[hole outer])
      expect(report.contours.map(&:direction)).to eq(
        %i[counterclockwise clockwise],
      )
      expect(report.issues).to be_empty
    end

    it 'reports blank glyphs as unsupported' do
      glyph_id = file.cmap.unicode.first[0x20] # space
      report = inspector.inspect_glyph(glyph_id)
      expect(report).not_to be_supported
      expect(report.unsupported_reason).to eq('blank glyph')
    end

    it 'reports compound glyphs as unsupported' do
      glyph_id = file.cmap.unicode.first[0xC0] # 'À'
      report = inspector.inspect_glyph(glyph_id)
      expect(report).not_to be_supported
      expect(report.unsupported_reason).to eq('compound glyph')
    end
  end
end
