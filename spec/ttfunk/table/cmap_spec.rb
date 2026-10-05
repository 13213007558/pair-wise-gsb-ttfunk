# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cmap'

RSpec.describe TTFunk::Table::Cmap do
  describe '.encode' do
    let(:reconstituted) do
      described_class.new(TestFile.new(StringIO.new(result[:table])))
    end

    context 'with only character mappings' do
      let(:result) { described_class.encode({ 0x20 => 3, 0x41 => 5 }, :unicode) }

      it 'encodes a single encoding record' do
        expect(reconstituted.tables.size).to eq(1)
      end

      it 'encodes character mappings' do
        expect(reconstituted.unicode.first[0x41]).to eq(2)
      end

      it 'encodes no UVS record' do
        expect(reconstituted.uvs).to be_nil
      end
    end

    context 'with variation sequences' do
      let(:result) do
        described_class.encode(
          {
            0x20 => 3,
            0x4E2D => 5,
            [0x4E2D, 0xE0100] => 7,
            [0x4E2D, 0xFE00] => nil,
          },
          :unicode,
        )
      end

      it 'encodes two encoding records' do
        expect(reconstituted.tables.size).to eq(2)
      end

      it 'encodes the base character mappings in a Unicode record' do
        unicode = reconstituted.unicode.first

        expect(unicode.platform_id).to eq(3)
        expect(unicode.encoding_id).to eq(1)
        expect(unicode[0x4E2D]).to eq(2)
      end

      it 'encodes variation sequences in a format 14 record' do
        uvs = reconstituted.uvs

        expect(uvs.format).to eq(14)
        expect(uvs.platform_id).to eq(0)
        expect(uvs.encoding_id).to eq(5)
      end

      it 'encodes non-default UVS with renumbered glyph IDs' do
        expect(reconstituted.uvs[0x4E2D, 0xE0100]).to eq(3)
      end

      it 'encodes default UVS' do
        expect(reconstituted.uvs.default_uvs?(0x4E2D, 0xFE00)).to be(true)
      end

      it 'accounts for variation glyphs in max glyph ID' do
        expect(result[:max_glyph_id]).to eq(4)
      end

      it 'includes variation sequences in the charmap' do
        expect(result[:charmap][[0x4E2D, 0xE0100]]).to eq(old: 7, new: 3)
      end
    end
  end
end
