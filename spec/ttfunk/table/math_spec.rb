# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::Table::MathTable do
  let(:font) { TTFunk::File.new(MiniMathFont.build) }
  let(:math) { font.math }

  it 'rejects an unsupported stretch direction' do
    expect do
      math.stretch_plan_for(10, 100, :diagonal)
    end.to raise_error(ArgumentError, 'unsupported direction diagonal')
  end

  it 'parses MathVariants constructions and parts' do
    construction = math.construction_for(10, :vertical)

    expect(math.variants.min_connector_overlap).to eq(10)
    expect(construction.variants.map(&:glyph_id)).to eq([11])
    expect(construction.assembly.italic_correction).to eq(7)
    expect(construction.assembly.parts.map(&:glyph_id)).to eq([1, 2, 3, 4])
    expect(construction.assembly.parts.map(&:extender?)).to eq(
      [false, true, true, false],
    )
  end

  it 'uses the smallest sufficiently large variant and its italic correction' do
    plan = math.stretch_plan_for(10, 120, :vertical)

    expect(plan.actual_advance).to eq(120)
    expect(plan.italic_correction).to eq(5)
    expect(plan.segments.map(&:glyph_id)).to eq([11])
    expect(plan.segments.first.position).to eq(0)
  end

  it 'assembles vertically at a connector upper bound with fewest extenders' do
    plan = math.stretch_plan_for(10, 145, :vertical)

    expect(plan.actual_advance).to eq(145)
    expect(plan.italic_correction).to eq(7)
    expect(plan.segments.map(&:glyph_id)).to eq([1, 2, 3, 3, 4])
    expect(plan.segments.map(&:position)).to eq([0, 30, 50, 80, 105])
    expect(plan.segments.map(&:overlap_before)).to eq([0, 10, 10, 10, 15])
  end

  it 'assembles a horizontal arrow using each connector upper bound' do
    plan = math.stretch_plan_for(20, 50, :horizontal)

    expect(plan.actual_advance).to eq(50)
    expect(plan.italic_correction).to eq(0)
    expect(plan.segments.map(&:glyph_id)).to eq([5, 6, 7])
    expect(plan.segments.map(&:position)).to eq([0, 20, 20])
    expect(plan.segments.map(&:overlap_before)).to eq([0, 10, 20])
  end

  it 'uses minimum overlaps at the horizontal assembly maximum advance' do
    plan = math.stretch_plan_for(20, 60, :horizontal)

    expect(plan.actual_advance).to eq(60)
    expect(plan.segments.map(&:position)).to eq([0, 20, 30])
    expect(plan.segments.map(&:overlap_before)).to eq([0, 10, 10])
  end

  it 'reports a symbol with variants but no glyph assembly' do
    expect do
      math.stretch_plan_for(30, 100, :vertical)
    end.to raise_error(
      described_class::StretchPlan::NoAssemblyError,
      'glyph 30 has no vertical glyph assembly',
    )
  end

  it 'reports a glyph without any stretch construction' do
    expect do
      math.stretch_plan_for(99, 100, :vertical)
    end.to raise_error(
      described_class::StretchPlan::NoAssemblyError,
      'glyph 99 has no vertical glyph assembly',
    )
  end

  it 'reports an advance outside an assembly reachable interval' do
    expect do
      math.stretch_plan_for(40, 60, :vertical)
    end.to raise_error(described_class::StretchPlan::UnreachableAdvanceError)
  end

  it 'reports an indefinitely large target an extender assembly cannot reach' do
    expect do
      math.stretch_plan_for(10, 10_001, :vertical)
    end.to raise_error(described_class::StretchPlan::UnreachableAdvanceError)
  end
end
