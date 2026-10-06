# frozen_string_literal: true

require 'spec_helper'
RSpec.describe TTFunk::VariableFontInstantiator do
  let(:font) { TTFunk::File.open(test_font('VariableTest')) }

  def instantiate(location)
    font.instantiate_variable_font(location)
  end

  def static_font(result)
    TTFunk::File.open(StringIO.new(result.font_data))
  end

  describe '#instantiate' do
    it 'applies avar, interpolates omitted points, phantoms, and composites' do
      result = instantiate('wght' => 650)
      static = static_font(result)
      glyph = static.glyph_outlines.for(1)
      compound = static.glyph_outlines.for(3)

      expect(result.normalized_coordinates).to eq('wght' => 0.25)
      expect(glyph.coordinates).to eq([
        [113, 0], [225, 400], [338, 0],
      ])
      expect([glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max]).to eq(
        [113, 0, 338, 400]
      )
      expect(static.horizontal_metrics.for(1).to_a).to eq([450, 63])
      expect(compound.components.map { |component|
        [component.arg1, component.arg2]
      }).to eq([[3, 5]])
      expect([
        compound.x_min, compound.y_min, compound.x_max, compound.y_max
      ]).to eq([3, 5, 103, 105])
      expect(static.horizontal_metrics.for(3).to_a).to eq([200, 3])
      expect(static.horizontal_metrics.for(0).to_a).to eq([538, -7])
    end

    it 'clamps out-of-range axis coordinates to the valid axis range' do
      result = instantiate('wght' => 1000)
      static = static_font(result)
      glyph = static.glyph_outlines.for(1)

      expect(result.user_coordinates).to eq('wght' => 1000.0)
      expect(result.clamped_coordinates).to eq('wght' => 900.0)
      expect(result.normalized_coordinates).to eq('wght' => 1.0)
      expect(glyph.coordinates).to eq([
        [150, 0], [300, 400], [450, 0],
      ])
      expect(static.horizontal_metrics.for(1).to_a).to eq([300, -50])
    end

    it 'writes a static SFNT and lists deleted or rewritten tables' do
      result = instantiate('wght' => 900)
      static = static_font(result)

      expect(static.directory.tables).not_to include(
        'fvar', 'avar', 'gvar', 'DSIG'
      )
      expect(result.removed_tables).to eq(%w[avar DSIG fvar gvar])
      expect(result.rewritten_tables).to eq(%w[glyf head hhea hmtx loca])
      expect(static.header.index_to_loc_format).to eq(1)
      expect(static.header.checksum_adjustment).not_to be_zero
    end

    it 'does not silently discard an unsupported variation table' do
      unsupported_font = TTFunk::File.open(test_font('VariableTestWithHvar'))

      expect {
        unsupported_font.instantiate_variable_font('wght' => 900)
      }.to raise_error(TTFunk::Error, /HVAR/)
    end

    it 'requires every fvar axis coordinate' do
      expect {
        instantiate({})
      }.to raise_error(ArgumentError, /missing axis coordinates: wght/)
    end

    it 'parses fvar, avar, and embedded gvar tuples' do
      variation = font.glyph_variations.for(1).first

      expect(font.font_variations.axes.map(&:tag)).to eq(['wght'])
      expect(font.axis_variations.axis_segments.first[0.5]).to eq(0.25)
      expect(variation.peak).to eq('wght' => 1.0)
      expect(variation.deltas[1]).to be_nil
      expect(variation.deltas[3]).to eq([200, 0])
    end
  end
end
