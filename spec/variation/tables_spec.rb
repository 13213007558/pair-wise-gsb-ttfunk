# frozen_string_literal: true

require 'ttfunk'

RSpec.describe 'variable table parsers' do
  let(:file) { TTFunk::File.open(test_path('VariableTest.ttf')) }

  def test_path(name)
    File.expand_path('../fonts', __dir__) + "/#{name}"
  end

  describe 'fvar' do
    it 'parses a single weight axis with its range' do
      expect(file.fvar.axes.length).to eq(1)
      axis = file.fvar.axes.first
      expect(axis.tag).to eq('wght')
      expect(axis.min_value).to be_within(1e-6).of(100)
      expect(axis.default_value).to be_within(1e-6).of(400)
      expect(axis.max_value).to be_within(1e-6).of(900)
    end

    it 'normalizes and clamps a design-space coordinate' do
      axis = file.fvar.axes.first
      expect(axis.normalize(900)).to eq(1.0)
      expect(axis.normalize(400)).to eq(0.0)
      expect(axis.normalize(100)).to eq(-1.0)
      expect(axis.normalize(50)).to eq(-1.0)
      expect(axis.normalize(1500)).to eq(1.0)
      expect(axis.normalize(650)).to be_within(1e-9).of(0.5)
    end
  end

  describe 'avar' do
    it 'applies a piecewise linear segment map' do
      mapping = { 'wght' => 0.5 }
      expect(file.avar.apply(mapping)['wght']).to eq(0.70001220703125)
    end

    it 'interpolates between mapped keys' do
      mapping = { 'wght' => 0.25 }
      # halfway between 0 and the 0.5->0.7 key
      expect(file.avar.apply(mapping)['wght']).to be_within(1e-3).of(0.35)
    end

    it 'extrapolates outside the mapped keys' do
      mapping = { 'wght' => 1.5 }
      expect(file.avar.apply(mapping)['wght']).to eq(1.5)
    end
  end

  describe 'gvar' do
    it 'decodes shared-point tuples with phantom deltas' do
      space_id = file.cmap.unicode.first.code_map.fetch(0x20)
      variations = file.gvar.for(space_id, 4)
      expect(variations.length).to eq(1)
      tuple = variations.first
      expect(tuple.axes['wght']).to eq([0.0, 1.0, 1.0])
      expect(tuple.deltas[1]).to eq([120, 0])
      # omitted points remain nil
      expect(tuple.deltas[0]).to be_nil
      expect(tuple.deltas[2]).to be_nil
    end

    it 'decodes a composite glyph using n+4 pseudo-points' do
      composite_id = file.maximum_profile.num_glyphs - 1
      raw = file.glyph_outlines.for(composite_id)
      point_count = raw.glyph_ids.length + 4
      tuple = file.gvar.for(composite_id, point_count).first
      expect(tuple.deltas[1]).to eq([30, 40])
      expect(tuple.deltas[3]).to eq([20, 0])
    end
  end
end
