# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::OutlineCheck do
  def check(contours, glyph_id: 7)
    described_class.check_contours(contours, glyph_id: glyph_id)
  end

  # Shoelace area of the raw point polygon (off-curve points connected
  # straight). This is what a naive check would compute; the whole point of
  # these tests is that the real curve behaves differently.
  def control_polygon_area(contour)
    points = contour.map { |x, y, _on| [x, y] }
    points.each_with_index.sum { |p, i|
      q = points[(i + 1) % points.length]
      (p[0] * q[1]) - (q[0] * p[1])
    } / 2.0
  end

  describe TTFunk::OutlineCheck::Segment do
    it 'computes the true signed area of a quadratic curve analytically' do
      segment = described_class.new([0, -100], [100, 0], [90, 0])

      # reference: dense sampling of the actual curve
      steps = 4096
      sampled = (0..steps).map { |i| segment.point_at(i.to_f / steps) }
      reference = sampled.each_cons(2).sum { |a, b|
        ((a[0] * b[1]) - (b[0] * a[1])) / 2.0
      }

      expect(segment.signed_area).to be_within(1e-3).of(reference)
    end

    it 'can disagree with the control polygon about direction' do
      # The control polygon (0,100) -> (0,-40) -> (10,0) sweeps a clearly
      # positive (counter-clockwise) area, but the curve itself dips below
      # the chord and its true swept area is negative.
      segment = described_class.new([0, 100], [0, -40], [10, 0])

      polygon_area = (
        TTFunk::OutlineCheck::Geometry.cross([0, 100], [0, -40]) +
        TTFunk::OutlineCheck::Geometry.cross([0, -40], [10, 0]) +
        TTFunk::OutlineCheck::Geometry.cross([10, 0], [0, 100])
      ) / 2.0

      expect(polygon_area).to be_positive
      expect(segment.signed_area).to be_within(1e-9).of(-100.0 / 3)
      expect(segment.signed_area).to be_negative
    end
  end

  describe 'contour orientation' do
    # A simple (non-self-intersecting) closed contour whose control polygon
    # runs counter-clockwise (area +102) while the true curve area is
    # clockwise (-133.67). Judging direction from the control polygon would
    # misclassify this contour.
    let(:misleading) do
      [
        [0, 100, true], [0, -40, false], [10, 0, true],
        [0, -10, true], [0, 4, false], [-1, 0, true],
      ]
    end

    it 'takes orientation from the curve, not the control polygon' do
      expect(control_polygon_area(misleading)).to be_positive

      report = check([misleading])
      contour = report.contours.first

      expect(contour.signed_area).to be_within(1e-9).of(-401.0 / 3)
      expect(contour.orientation).to eq(:clockwise)
    end

    it 'does not flag a contour whose curve orientation is conventional' do
      report = check([misleading])
      expect(report.contours.first.role).to eq(:outer)
      expect(report.issues.map(&:type))
        .not_to include(:unexpected_orientation)
    end

    it 'flags contours whose curve orientation defies the convention' do
      # counter-clockwise square: fine as a hole, suspicious as an outer
      ccw_square = [[0, 0, true], [100, 0, true], [100, 100, true], [0, 100, true]]
      report = check([ccw_square])

      expect(report.contours.first.role).to eq(:outer)
      expect(report.contours.first.orientation).to eq(:counter_clockwise)
      expect(report.issues.map(&:type)).to include(:unexpected_orientation)
    end
  end

  describe 'nesting' do
    let(:outer_square) do
      [[0, 0, true], [0, 100, true], [100, 100, true], [100, 0, true]]
    end
    let(:inner_square) do
      [[25, 25, true], [75, 25, true], [75, 75, true], [25, 75, true]]
    end

    it 'classifies outer contours and holes' do
      report = check([outer_square, inner_square])

      expect(report.contours.map(&:role)).to eq(%i[outer hole])
      expect(report.contours.map(&:orientation))
        .to eq(%i[clockwise counter_clockwise])
      expect(report.contours.map(&:depth)).to eq([0, 1])
      expect(report.issues).to be_empty
    end

    it 'computes true signed areas per contour' do
      report = check([outer_square, inner_square])

      expect(report.contours[0].signed_area).to be_within(1e-9).of(-10_000)
      expect(report.contours[1].signed_area).to be_within(1e-9).of(2_500)
    end
  end

  describe 'tangent hole' do
    # A hole whose top touches the outer contour at exactly one point with
    # a horizontal tangent. Nesting there is genuinely ambiguous.
    let(:outer_square) do
      [[0, 0, true], [0, 100, true], [100, 100, true], [100, 0, true]]
    end
    let(:tangent_hole) do
      [
        [50, 100, true], [10, 100, false], [10, 60, true],
        [10, 20, false], [50, 20, true], [90, 20, false],
        [90, 60, true], [90, 100, false],
      ]
    end

    it 'reports the tangency as an uncertain position' do
      report = check([outer_square, tangent_hole], glyph_id: 42)

      tangencies = report.issues.select { |issue| issue.type == :tangency }
      expect(tangencies).not_to be_empty

      issue = tangencies.first
      expect(issue.glyph_id).to eq(42)
      expect(issue.contour_indexes).to contain_exactly(0, 1)
      expect(issue.point[0]).to be_within(0.5).of(50)
      expect(issue.point[1]).to be_within(0.5).of(100)
      expect(issue.segments.first.first).to eq(issue.contour_indexes.first)
      expect(issue.parameters.length).to eq(2)
      expect(issue.parameters).to all(be_between(0.0, 1.0).inclusive)
    end

    it 'marks nesting of touching contours as uncertain' do
      report = check([outer_square, tangent_hole])

      expect(report.contours.map(&:role)).to eq(%i[uncertain uncertain])
    end

    it 'still computes true curve areas for the touching contours' do
      report = check([outer_square, tangent_hole])

      expect(report.contours[0].signed_area).to be_within(1e-9).of(-10_000)
      expect(report.contours[1].signed_area).to be_positive
    end
  end

  describe 'self-intersection' do
    # Figure-eight built from two quadratic curves crossing once.
    let(:figure_eight) do
      [
        [0, 0, true], [100, 100, false], [100, 0, true],
        [0, 100, false], [-20, 0, true],
      ]
    end

    it 'reports the crossing with curve parameter positions' do
      report = check([figure_eight], glyph_id: 9)

      issues = report.issues.select { |issue| issue.type == :self_intersection }
      expect(issues.length).to eq(1)

      issue = issues.first
      expect(issue.glyph_id).to eq(9)
      expect(issue.contour_indexes).to eq([0])
      expect(issue.segments).to eq([[0, 0], [0, 1]])
      expect(issue.parameters[0]).to be_within(0.01).of(0.2873)
      expect(issue.parameters[1]).to be_within(0.01).of(0.2873)
      expect(issue.point[0]).to be_within(0.5).of(49.2)
      expect(issue.point[1]).to be_within(0.5).of(41.0)
    end
  end

  describe 'overlapping edges' do
    # Two collinear edges overlapping over x in 20..40 at y = 10.
    let(:spurred) do
      [
        [0, 0, true], [100, 0, true], [100, 10, true], [20, 10, true],
        [20, 20, true], [40, 20, true], [40, 10, true], [0, 10, true],
      ]
    end

    it 'reports the overlap with segment and parameter ranges' do
      report = check([spurred])

      issues = report.issues.select { |issue| issue.type == :overlap }
      expect(issues.length).to eq(1)

      issue = issues.first
      expect(issue.segments).to eq([[0, 2], [0, 6]])
      expect(issue.point[0]).to be_within(1e-9).of(30)
      expect(issue.point[1]).to be_within(1e-9).of(10)
      expect(issue.message).to include('overlap')
    end
  end

  describe 'implied on-curve points' do
    it 'expands contours with consecutive off-curve points' do
      all_off_curve = [
        [0, 50, false], [50, 0, false], [100, 50, false], [50, 100, false],
      ]
      report = check([all_off_curve])

      expect(report.contours.first.signed_area).to be_within(1e-9).of(12_500.0 / 3)
      expect(report.contours.first.orientation).to eq(:counter_clockwise)
    end
  end

  describe 'with a real font' do
    let(:file) { TTFunk::File.open(test_font('DejaVuSans')) }
    let(:glyph_id) { file.cmap.unicode.first[0x004F] } # 'O'

    it 'checks a glyph parsed from glyf table data' do
      report = described_class.check_glyph(file.find_glyph(glyph_id))

      expect(report.glyph_id).to eq(glyph_id)
      expect(report.contours.length).to eq(2)
      expect(report.contours.map(&:role)).to contain_exactly(:outer, :hole)
      expect(report.issues).to be_empty
    end

    it 'checks selected glyphs of a whole file' do
      reports = described_class.check_file(file, [glyph_id])

      expect(reports.length).to eq(1)
      expect(reports.first.glyph_id).to eq(glyph_id)
    end

    it 'notes compound glyphs without expanding them' do
      compound_id = file.cmap.unicode.first[0x00C0] # 'À'
      report = described_class.check_glyph(file.find_glyph(compound_id))

      expect(report.notes).to eq([:compound_glyph_not_expanded])
      expect(report).not_to be_problematic
    end

    it 'returns nothing for CFF-based fonts' do
      cff_file = TTFunk::File.open(test_font('Exo-Regular', :otf))
      expect(described_class.check_file(cff_file)).to eq([])
    end
  end
end
