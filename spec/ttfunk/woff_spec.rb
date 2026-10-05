# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset/unicode'

describe TTFunk::WOFF do
  describe '.open' do
    it 'restores a compressed WOFF 1 font as an SFNT font' do
      woff = described_class.open(StringIO.new(build_woff))
      font = woff.to_font

      expect(font.name.font_name.first).to eq('DejaVu Sans')
      expect(font.contents.read(4)).to eq("\x00\x00\x00\x01".b)
    end

    it 'opens WOFF 1 automatically through File.open' do
      font = TTFunk::File.open(StringIO.new(build_woff))

      expect(font).to be_a(TTFunk::File)
      expect(font.woff).to be_a(described_class)
      expect(font.name.font_name.first).to eq('DejaVu Sans')
    end

    it 'preserves metadata and private data without adding them to tables' do
      metadata = '<metadata version="1.0"></metadata>'.b
      private_data = 'caller-private'.b
      woff_data = build_woff(metadata: metadata, private_data: private_data)
      font = TTFunk::File.open(StringIO.new(woff_data))

      expect(font.woff_metadata).to eq(metadata)
      expect(font.woff_private_data).to eq(private_data)
      expect(font.woff.compressed_metadata).to eq(deflate(metadata))
      expect(font.directory.tables.keys).not_to include('meta', 'priv')
    end

    it 'accepts uncompressed font tables' do
      font = TTFunk::File.open(StringIO.new(build_woff(compress: false)))

      expect(font.name.font_name.first).to eq('DejaVu Sans')
    end

    it 'restores CFF-based OpenType fonts' do
      woff_data = build_woff(test_font('ComicJens-Regular', :otf))
      font = TTFunk::File.open(StringIO.new(woff_data))
      font.contents.rewind

      expect(font.contents.read(4)).to eq('OTTO'.b)
      expect(font.cff.exists?).to be(true)
      expect(font.name.font_name.first).to eq('Comic Jens')
    end

    it 'does not support WOFF 2' do
      woff2 = build_woff
      woff2[0, 4] = described_class::WOFF2_SIGNATURE

      expect { described_class.new(woff2) }.to raise_error(
        ArgumentError, 'WOFF 2 fonts are not supported'
      )
    end

    it 'rejects WOFF 2 through the automatic file entry point' do
      woff2 = build_woff
      woff2[0, 4] = described_class::WOFF2_SIGNATURE

      expect { TTFunk::File.open(StringIO.new(woff2)) }.to raise_error(
        ArgumentError, 'WOFF 2 fonts are not supported'
      )
    end
  end

  describe '#to_sfnt' do
    it 'rebuilds the directory with four-byte padded table data' do
      woff = described_class.new(build_woff)
      sfnt = woff.to_sfnt
      restored = TTFunk::File.new(sfnt)

      restored.directory.tables.each_value do |entry|
        expect(entry[:offset] % 4).to eq(0)
        expect(entry[:length]).to be_positive
      end

      offsets = restored.directory.tables.values.map { |entry| [entry[:offset], entry[:length]] }
      expect(offsets).to eq(offsets.sort)
    end

    it 'sets a valid whole-font checksum adjustment' do
      sfnt = described_class.new(build_woff).to_sfnt
      head_entry = TTFunk::File.new(sfnt).directory_info('head')
      head = sfnt.byteslice(head_entry[:offset], head_entry[:length]).dup
      head[8, 4] = [0].pack('N')

      expect(sfnt_checksum(sfnt)).to eq(0xB1B0AFBA)
      expect(head_entry[:checksum]).to eq(sfnt_checksum(head))
    end

    it 'produces an SFNT that can be subsetted' do
      font = TTFunk::File.open(StringIO.new(build_woff))
      subset = TTFunk::Subset::Unicode.new(font)
      subset.use('a'.ord)
      subset_font = TTFunk::File.new(subset.encode)

      expect(subset_font.name.font_name.first).to eq('DejaVu Sans')
      expect(sfnt_checksum(subset.encode)).to eq(0xB1B0AFBA)
    end
  end

  describe 'validation' do
    it 'reports a decompressed length mismatch with its table tag' do
      data = build_woff
      woff = described_class.new(data)
      tag = 'name'
      entry = woff.to_font.directory_info(tag)
      actual_data = woff.to_font.contents.string.byteslice(entry[:offset], entry[:length])
      corrupted = build_woff(
        table_data: { tag => actual_data + 'x'.b },
        table_lengths: { tag => actual_data.length },
        table_checksums: { tag => entry[:checksum] }
      )

      expect { described_class.new(corrupted) }.to raise_error(
        TTFunk::Error, /decompressed length mismatch for "name"/
      )
    end

    it 'reports a table checksum mismatch with its table tag' do
      data = build_woff
      woff = described_class.new(data)
      tag = 'name'
      restored = woff.to_font
      entry = restored.directory_info(tag)
      actual_data = restored.contents.string.byteslice(entry[:offset], entry[:length])
      corrupted = build_woff(
        table_data: { tag => corrupt_byte(actual_data, 0) },
        table_lengths: { tag => actual_data.length },
        table_checksums: { tag => entry[:checksum] }
      )

      expect { described_class.new(corrupted) }.to raise_error(
        TTFunk::Error, /checksum mismatch for font table "name"/
      )
    end

    it 'reports overlapping compressed table data with its table tag' do
      corrupted = build_woff(table_offsets: { 'post' => 44 + (19 * 20) })

      expect { described_class.new(corrupted) }.to raise_error(
        TTFunk::Error, /"post".*overlap|overlap.*"post"/
      )
    end

    it 'reports when metadata overlaps a font table' do
      woff = build_woff(
        metadata: '<x/>'.b,
        metadata_offset: 44 + (19 * 20)
      )

      expect { described_class.new(woff) }.to raise_error(
        TTFunk::Error, /font table .* overlaps metadata block/
      )
    end

    it 'reports a malformed compressed table stream with its tag' do
      data = build_woff
      tag = 'name'
      woff = described_class.new(data)
      entry = woff.to_font.directory_info(tag)
      actual_data = woff.to_font.contents.string.byteslice(entry[:offset], entry[:length])
      corrupted_stream = +"\x78\x9Cnot-a-zlib-stream".b
      corrupted = build_woff(
        table_stored_data: { tag => corrupted_stream },
        table_data: { tag => actual_data },
        table_compressed_lengths: { tag => corrupted_stream.length },
        table_lengths: { tag => actual_data.length }
      )

      expect { described_class.new(corrupted) }.to raise_error(
        TTFunk::Error, /unable to decompress "name"/
      )
    end
  end
end
