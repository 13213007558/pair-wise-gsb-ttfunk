# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cmap'

RSpec.describe TTFunk::Table::Cmap::Format14 do
  def cmap_with_subtable(subtable)
    table = [0, 1].pack('nn') + [0, 5, 12].pack('nnN') + subtable
    TTFunk::Table::Cmap.new(TestFile.new(StringIO.new(table)))
  end

  # Assembles a format 14 subtable from raw parts so malformed data can be
  # injected. Each record is a hash with a :selector and optional :default
  # and :non_default serialized UVS tables.
  def build_subtable(records)
    offset = 10 + (records.length * 11)
    body = +''.b

    fields = records.map do |record|
      offsets = {}
      [:default, :non_default].each do |kind|
        data = record[kind]
        offsets[kind] = data ? offset : 0
        next unless data

        body << data
        offset += data.length
      end
      uint24(record[:selector]) + [offsets[:default], offsets[:non_default]].pack('NN')
    end

    [14, offset, records.length].pack('nNN') + fields.join + body
  end

  def uint24(value)
    [value].pack('N')[1, 3]
  end

  let(:default_uvs_table) { [1].pack('N') + uint24(0x4E00) + [0].pack('C') }
  let(:non_default_uvs_table) { [1].pack('N') + uint24(0x4E00) + [3].pack('n') }

  describe 'parsing' do
    let(:cmap) do
      cmap_with_subtable(
        build_subtable(
          [
            { selector: 0xFE00, default: default_uvs_table },
            { selector: 0xFE01, non_default: non_default_uvs_table },
          ],
        ),
      )
    end
    let(:uvs) { cmap.uvs }

    it 'distinguishes default, non-default, and unsupported sequences' do
      expect(uvs[0x4E00, 0xFE00]).to eq(:default)
      expect(uvs[0x4E00, 0xFE01]).to eq(3)
      expect(uvs[0x4E01, 0xFE00]).to be_nil
      expect(uvs[0x4E00, 0xFE02]).to be_nil
    end

    it 'lists variation selectors' do
      expect(uvs.selectors).to eq([0xFE00, 0xFE01])
    end

    it 'is not treated as a Unicode cmap' do
      expect(cmap.unicode).to be_empty
    end

    it 'raises a locatable error for out-of-bounds offsets' do
      subtable = build_subtable([{ selector: 0xFE00 }])
      subtable[13, 4] = [9999].pack('N')

      expect { cmap_with_subtable(subtable) }
        .to raise_error(TTFunk::Error, /offset 9999.*U\+FE00/)
    end

    it 'raises a locatable error for offsets into the record header' do
      subtable = build_subtable([{ selector: 0xFE00 }])
      subtable[13, 4] = [5].pack('N')

      expect { cmap_with_subtable(subtable) }
        .to raise_error(TTFunk::Error, /offset 5.*U\+FE00/)
    end

    it 'raises a locatable error for duplicate selectors' do
      subtable = build_subtable([{ selector: 0xFE00 }, { selector: 0xFE00 }])

      expect { cmap_with_subtable(subtable) }
        .to raise_error(TTFunk::Error, /duplicate variation selector U\+FE00/)
    end
  end

  describe '.encode' do
    it 'round-trips selectors, ranges, and mappings' do
      subtable =
        described_class.encode(
          0xFE01 => { default: [], non_default: { 0x4E00 => 3 } },
          0xFE00 => { default: [0x4E01, 0x4E00], non_default: {} },
        )
      uvs = cmap_with_subtable(subtable).uvs

      expect(uvs.selectors).to eq([0xFE00, 0xFE01])
      expect(uvs[0x4E00, 0xFE00]).to eq(:default)
      expect(uvs[0x4E01, 0xFE00]).to eq(:default)
      expect(uvs[0x4E02, 0xFE00]).to be_nil
      expect(uvs[0x4E00, 0xFE01]).to eq(3)
    end

    it 'produces a subtable with the declared length' do
      subtable =
        described_class.encode(
          0xFE00 => { default: [0x4E00], non_default: { 0x4E01 => 5 } },
        )

      expect(subtable.unpack1('n')).to eq(14)
      expect(subtable[2, 4].unpack1('N')).to eq(subtable.length)
    end
  end
end
