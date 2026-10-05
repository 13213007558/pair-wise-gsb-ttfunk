# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset/unicode'

RSpec.describe TTFunk::Subset::Unicode do
  # A small artificial font containing:
  # * a Unicode cmap mapping space to glyph 1 and U+6F22 to glyph 2
  # * a format 14 cmap mapping U+6F22 U+E0100 to glyph 3 (non-default UVS)
  #   and U+6F22 U+E0101 to the default glyph (default UVS)
  let(:original_cmap) do
    encoded = TTFunk::Table::Cmap.encode(
      { 0x20 => 1, 0x6F22 => 2 },
      :unicode,
      { [0x6F22, 0xE0100] => 3, [0x6F22, 0xE0101] => 0 },
    )
    TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(encoded[:table])))
  end
  let(:original) { instance_double(TTFunk::File, cmap: original_cmap) }
  let(:subset) { described_class.new(original) }

  it 'includes variation sequence glyphs in the subset' do
    subset.use(0x6F22, 0xE0100)
    expect(subset.original_glyph_ids).to eq([0, 1, 2, 3])
  end

  it 'does not treat the variation selector as a character' do
    subset.use(0x6F22, 0xE0100)
    expect(subset.includes?(0x6F22)).to be(true)
    expect(subset.includes?(0xE0100)).to be(false)
  end

  it 'preserves default UVS entries' do
    subset.use(0x6F22, 0xE0101)
    uvs = subset.new_cmap_table[:uvs]
    expect(uvs[[0x6F22, 0xE0101]]).to eq(old: 0, new: 0)
  end

  it 'skips unsupported variation sequences' do
    subset.use(0x6F22, 0xE0102)
    expect(subset.new_cmap_table[:uvs]).to be_nil
    expect(subset.original_glyph_ids).to eq([0, 1, 2])
  end

  it 'encodes a subset cmap that can be read back' do
    subset.use(0x6F22, 0xE0100)
    subset.use(0x6F22, 0xE0101)

    encoded = subset.new_cmap_table
    cmap = TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(encoded[:table])))
    uvs_table = cmap.variation

    expect(uvs_table[0x6F22, 0xE0100]).to eq(3)
    expect(uvs_table[0x6F22, 0xE0101]).to eq(0)
    expect(uvs_table[0x6F22, 0xE0102]).to be_nil
    expect(cmap.unicode.first[0x6F22]).to eq(2)
  end
end
