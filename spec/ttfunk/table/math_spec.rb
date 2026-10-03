# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/math'

SYSTEM_MATH_FONT = '/System/Library/Fonts/Supplemental/STIXTwoMath.otf'

RSpec.describe TTFunk::Table::Math do
  let(:glyph_ids) { { brace: 10, plain: 30, arrow: 50 } }

  let(:math_table) do
    table = described_class.allocate
    table.instance_variable_set(:@min_connector_overlap, 20)
    table.instance_variable_set(:@vertical_glyphs, [glyph_ids[:brace], glyph_ids[:plain]])
    table.instance_variable_set(:@horizontal_glyphs, [glyph_ids[:arrow]])
    table.instance_variable_set(:@vertical_glyph_count, 2)
    table.instance_variable_set(:@horizontal_glyph_count, 1)
    table.instance_variable_set(:@vertical_construction_offsets, [0, 1])
    table.instance_variable_set(:@horizontal_construction_offsets, [2])
    table.instance_variable_set(:@construction_cache, {
      [described_class::VERTICAL, 0] => brace_construction,
      [described_class::VERTICAL, 1] => plain_construction,
      [described_class::HORIZONTAL, 0] => arrow_construction,
    })
    table
  end

  let(:brace_assembly) do
    described_class::Assembly.new(-7, [
      part(20, 20, 20, 80, false),
      part(21, 20, 20, 50, true),
      part(22, 20, 20, 70, false),
      part(23, 20, 20, 50, true),
      part(24, 20, 20, 80, false),
    ])
  end

  let(:arrow_assembly) do
    described_class::Assembly.new(0, [
      part(51, 50, 50, 60, true),
      part(52, 20, 0, 50, false),
    ])
  end

  let(:brace_construction) do
    described_class::Construction.new(brace_assembly, [
      variant(101, 100, 0),
      variant(102, 190, 11),
    ])
  end

  let(:plain_construction) do
    described_class::Construction.new(nil, [variant(301, 100, 0)])
  end

  let(:arrow_construction) do
    described_class::Construction.new(arrow_assembly, [])
  end

  it 'uses the smallest sufficiently large ready-made variant' do
    stretch = math_table.stretch(glyph_ids[:brace], 190, described_class::VERTICAL)

    expect(stretch).to be_variant
    expect(stretch.glyph_id).to eq(102)
    expect(stretch.actual_advance).to eq(190)
    expect(stretch.italic_correction).to eq(11)
    expect(stretch.segments).to eq([segment(102, 0, 190, 190)])
  end

  it 'builds at the maximum connector overlap while honoring part order' do
    stretch = math_table.stretch(glyph_ids[:brace], 250, described_class::VERTICAL)

    expect(stretch).to be_assembly
    expect(stretch.actual_advance).to eq(250)
    expect(stretch.italic_correction).to eq(-7)
    expect(stretch.segments).to eq([
      segment(20, 0, 60, 80),
      segment(21, 60, 30, 110),
      segment(22, 90, 50, 160),
      segment(23, 140, 30, 190),
      segment(24, 170, 80, 250),
    ])
  end

  it 'uses the minimum number of extender copies and breaks ties by part order' do
    stretch = math_table.stretch(glyph_ids[:brace], 280, described_class::VERTICAL)
    larger = math_table.stretch(glyph_ids[:brace], 310, described_class::VERTICAL)

    expect(stretch.segments.map(&:glyph_id)).to eq([20, 21, 21, 22, 23, 24])
    expect(stretch.actual_advance).to eq(280)
    expect(larger.segments.map(&:glyph_id)).to eq([20, 21, 21, 21, 22, 23, 24])
    expect(larger.actual_advance).to eq(310)
  end

  it 'plans horizontal assemblies and places extender copies in part order' do
    stretch = math_table.stretch(glyph_ids[:arrow], 100, described_class::HORIZONTAL)

    expect(stretch.direction).to eq(described_class::HORIZONTAL)
    expect(stretch.actual_advance).to eq(100)
    expect(stretch.segments).to eq([
      segment(51, 0, 10, 60),
      segment(51, 10, 40, 70),
      segment(52, 50, 50, 100),
    ])
  end

  it 'raises a descriptive error when no variant or assembly can reach the target' do
    expect { math_table.stretch(glyph_ids[:plain], 300, described_class::VERTICAL) }
      .to raise_error(TTFunk::Error, /no vertical glyph assembly/)
  end

  it 'raises a descriptive error when the glyph is not covered for the direction' do
    expect { math_table.stretch(glyph_ids[:arrow], 100, described_class::VERTICAL) }
      .to raise_error(TTFunk::Error, /not covered/)
  end

  it 'parses a system MATH font when one is available', if: File.exist?(SYSTEM_MATH_FONT) do
    font = TTFunk::File.open(SYSTEM_MATH_FONT)
    glyph_id = font.cmap.unicode.first[0x7B]
    stretch = font.math.stretch(glyph_id, 4000, described_class::VERTICAL)

    expect(font.math.version).to eq(0x00010000)
    expect(stretch).to be_assembly
    expect(stretch.actual_advance).to be >= 4000
    expect(stretch.segments).not_to be_empty

    arrow = font.cmap.unicode.first[0x2192]
    horizontal = font.math.stretch(arrow, 1000, described_class::HORIZONTAL)
    expect(horizontal).to be_assembly
    expect(horizontal.actual_advance).to be >= 1000
  end

  def segment(glyph_id, position, advance, end_position)
    described_class::Segment.new(glyph_id, position, advance, end_position)
  end

  def part(glyph_id, start_connector, end_connector, advance, extender)
    described_class::Part.new(
      glyph_id,
      start_connector,
      end_connector,
      advance,
      extender,
    )
  end

  def variant(glyph_id, advance, italic_correction)
    described_class::Variant.new(glyph_id, advance, italic_correction)
  end
end
