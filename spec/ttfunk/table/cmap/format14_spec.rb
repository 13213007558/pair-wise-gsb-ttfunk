# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cmap'

RSpec.describe TTFunk::Table::Cmap::Format14 do
  let(:subtable) do
    # An artificial format 14 subtable with two variation selectors:
    # * U+FE00 with a default UVS table mapping U+4E2D to the default glyph
    # * U+E0100 with a non-default UVS table mapping U+4E2D to glyph 5 and
    #   U+6F22 to glyph 9
    default_uvs = [1].pack('N') + [0x4E2D].pack('N')[1..] + [0].pack('C')
    non_default_uvs =
      [2].pack('N') +
      [0x4E2D].pack('N')[1..] + [5].pack('n') +
      [0x6F22].pack('N')[1..] + [9].pack('n')

    default_offset = 10 + (2 * 11)
    non_default_offset = default_offset + default_uvs.length
    length = non_default_offset + non_default_uvs.length

    [14, length, 2].pack('nNN') +
      [0xFE00].pack('N')[1..] + [default_offset, 0].pack('NN') +
      [0xE0100].pack('N')[1..] + [0, non_default_offset].pack('NN') +
      default_uvs + non_default_uvs
  end

  let(:cmap_table) do
    [0, 1, 0, 5, 12].pack('nnnnN') + subtable
  end

  let(:cmap) { TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(cmap_table))) }
  let(:format14) { cmap.uvs }

  it 'is supported' do
    expect(format14.supported?).to be(true)
  end

  it 'is not a Unicode cmap' do
    expect(cmap.unicode).to be_empty
  end

  it 'parses variation selectors' do
    expect(format14.variation_selectors.keys).to eq([0xFE00, 0xE0100])
  end

  it 'parses default UVS ranges' do
    expect(format14.variation_selectors[0xFE00][:default]).to eq([[0x4E2D, 1]])
  end

  it 'parses non-default UVS mappings' do
    expect(format14.variation_selectors[0xE0100][:non_default])
      .to eq(0x4E2D => 5, 0x6F22 => 9)
  end

  describe '#[]' do
    it 'returns glyph ID for non-default variation sequences' do
      expect(format14[0x4E2D, 0xE0100]).to eq(5)
      expect(format14[0x6F22, 0xE0100]).to eq(9)
    end

    it 'returns nil for default variation sequences' do
      expect(format14[0x4E2D, 0xFE00]).to be_nil
    end

    it 'returns nil for unknown variation sequences' do
      expect(format14[0x4E2D, 0xFE01]).to be_nil
      expect(format14[0x6F22, 0xFE00]).to be_nil
    end
  end

  describe '#default_uvs?' do
    it 'is true for default variation sequences' do
      expect(format14.default_uvs?(0x4E2D, 0xFE00)).to be(true)
    end

    it 'is false for non-default variation sequences' do
      expect(format14.default_uvs?(0x4E2D, 0xE0100)).to be(false)
    end

    it 'is false for unknown variation sequences' do
      expect(format14.default_uvs?(0x4E2D, 0xFE01)).to be(false)
      expect(format14.default_uvs?(0x6F22, 0xFE00)).to be(false)
    end
  end

  describe '.encode' do
    let(:base_charmap) do
      {
        0x20 => { old: 3, new: 1 },
        0x4E2D => { old: 5, new: 2 },
      }
    end

    let(:charmap) do
      {
        [0x4E2D, 0xE0100] => 7, # non-default
        [0x4E2D, 0xFE00] => nil, # default
      }
    end

    let(:result) { described_class.encode(charmap, base_charmap, 3) }

    let(:reconstituted) do
      table = [0, 1, 0, 5, 12].pack('nnnnN') + result[:subtable]
      TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(table))).uvs
    end

    it 'can be read back' do
      expect(reconstituted).to be_supported
    end

    it 'encodes non-default UVS mappings with renumbered glyph IDs' do
      expect(reconstituted[0x4E2D, 0xE0100]).to eq(3)
    end

    it 'encodes default UVS mappings' do
      expect(reconstituted.default_uvs?(0x4E2D, 0xFE00)).to be(true)
    end

    it 'keeps default and non-default sequences distinct' do
      expect(reconstituted.default_uvs?(0x4E2D, 0xE0100)).to be(false)
      expect(reconstituted[0x4E2D, 0xFE00]).to be_nil
    end

    it 'includes non-default mappings in the charmap' do
      expect(result[:charmap]).to eq([0x4E2D, 0xE0100] => { old: 7, new: 3 })
    end

    it 'continues glyph numbering from the base charmap' do
      expect(result[:max_glyph_id]).to eq(4)
    end

    it 'reuses new glyph IDs of the base charmap' do
      charmap = { [0x4E2D, 0xE0100] => 5 }
      result = described_class.encode(charmap, base_charmap, 3)

      expect(result[:charmap]).to eq([0x4E2D, 0xE0100] => { old: 5, new: 2 })
      expect(result[:max_glyph_id]).to eq(3)
    end

    it 'raises an error when a default sequence has no base glyph' do
      expect {
        described_class.encode({ [0x6F22, 0xFE00] => nil }, base_charmap, 3)
      }.to raise_error(ArgumentError, /no base glyph/)
    end

    it 'merges consecutive codes into default UVS ranges' do
      base_charmap = {
        0x4E2D => { old: 5, new: 1 },
        0x4E2E => { old: 6, new: 2 },
        0x4E30 => { old: 7, new: 3 },
      }
      charmap = {
        [0x4E2D, 0xFE00] => nil,
        [0x4E2E, 0xFE00] => nil,
        [0x4E30, 0xFE00] => nil,
      }
      result = described_class.encode(charmap, base_charmap, 4)

      table = [0, 1, 0, 5, 12].pack('nnnnN') + result[:subtable]
      reconstituted =
        TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(table))).uvs

      expect(reconstituted.variation_selectors[0xFE00][:default])
        .to eq([[0x4E2D, 2], [0x4E30, 1]])
    end

    it 'splits default UVS ranges longer than 256 codes' do
      base_charmap =
        (0x4E2D..0x4F2D).to_h { |code| [code, { old: code, new: code }] }
      charmap =
        (0x4E2D..0x4F2D).to_h { |code| [[code, 0xFE00], nil] }
      result = described_class.encode(charmap, base_charmap, 0x4F2E)

      table = [0, 1, 0, 5, 12].pack('nnnnN') + result[:subtable]
      reconstituted =
        TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(table))).uvs

      expect(reconstituted.variation_selectors[0xFE00][:default])
        .to eq([[0x4E2D, 256], [0x4E2D + 256, 1]])
    end
  end
end
