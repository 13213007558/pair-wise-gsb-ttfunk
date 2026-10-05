# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cmap'

RSpec.describe TTFunk::Table::Cmap::Format14 do
  # A small artificial font: two encoded characters (space and U+6F22) and
  # a format 14 table with one non-default and one default variation
  # sequence.
  let(:charmap) { { 0x20 => 1, 0x6F22 => 2 } }
  let(:uvs_charmap) do
    {
      [0x6F22, 0xE0100] => 3, # non-default UVS
      [0x6F22, 0xE0101] => 0, # default UVS
    }
  end
  let(:encoded) { TTFunk::Table::Cmap.encode(charmap, :unicode, uvs_charmap) }
  let(:cmap) { TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(encoded[:table]))) }
  let(:uvs_table) { cmap.tables.find { |table| table.format == 14 } }

  it 'renumbers non-default UVS glyphs consistently with the base mapping' do
    expect(encoded[:charmap][0x6F22]).to eq(old: 2, new: 2)
    expect(encoded[:charmap]).not_to have_key(0xE0100)
    expect(encoded[:uvs][[0x6F22, 0xE0100]]).to eq(old: 3, new: 3)
    expect(encoded[:uvs][[0x6F22, 0xE0101]]).to eq(old: 0, new: 0)
    expect(encoded[:max_glyph_id]).to eq(4)
  end

  it 'encodes a table that can be read back' do
    expect(cmap.tables.size).to eq(2)
    expect(uvs_table).to be_supported
    expect(uvs_table).not_to be_unicode
    expect(cmap.unicode.map(&:format)).to eq([4])
    expect(cmap.variation).to eq(uvs_table)
  end

  it 'distinguishes non-default, default, and unsupported sequences' do
    expect(uvs_table[0x6F22, 0xE0100]).to eq(3)
    expect(uvs_table[0x6F22, 0xE0101]).to eq(0)
    expect(uvs_table[0x6F22, 0xE0102]).to be_nil
    expect(uvs_table[0x6F23, 0xE0100]).to be_nil
  end

  it 'keeps base character mapping in the regular Unicode cmap' do
    unicode_table = cmap.unicode.first
    expect(unicode_table[0x6F22]).to eq(2)
    expect(unicode_table[0xE0100]).to eq(0)
  end
end
