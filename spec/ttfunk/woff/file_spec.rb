# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset'

describe TTFunk::WOFF::File do
  # Builds a WOFF 1.0 container in memory from a tag => data table hash.
  def build_woff(tables, meta: nil, priv: nil, flavor: 0x00010000)
    tags = tables.keys.sort
    offset = 44 + (tags.length * 20)
    directory = []
    body = +''.b

    tags.each do |tag|
      raw = tables[tag]
      compressed = Zlib::Deflate.deflate(raw)
      compressed = raw if compressed.bytesize >= raw.bytesize
      checksum = raw.ljust((raw.bytesize + 3) & ~3, "\0")
        .unpack('N*').sum & 0xFFFF_FFFF

      directory << [tag, offset, compressed.bytesize, raw.bytesize, checksum]
      body << compressed
      body << "\0" * ((4 - (compressed.bytesize % 4)) % 4)
      offset += (compressed.bytesize + 3) & ~3
    end

    meta_offset = 0
    meta_length = 0
    meta_orig_length = 0
    if meta
      packed_meta = Zlib::Deflate.deflate(meta)
      meta_offset = offset
      meta_length = packed_meta.bytesize
      meta_orig_length = meta.bytesize
      body << packed_meta
      body << "\0" * ((4 - (packed_meta.bytesize % 4)) % 4)
      offset += (packed_meta.bytesize + 3) & ~3
    end

    priv_offset = 0
    priv_length = 0
    if priv
      priv_offset = offset
      priv_length = priv.bytesize
      body << priv
      offset += priv.bytesize
    end

    total_sfnt_size = 12 + (tags.length * 16) +
      tags.sum { |tag| (tables[tag].bytesize + 3) & ~3 }

    woff = [
      'wOFF', flavor, offset, tags.length, 0, total_sfnt_size, 1, 0,
      meta_offset, meta_length, meta_orig_length, priv_offset, priv_length,
    ].pack('a4N2n2Nn2N5')
    directory.each { |entry| woff << entry.pack('a4N4') }
    woff << body
    woff
  end

  # Byte offset of the directory entry for the given tag in a WOFF container.
  def woff_entry_position(woff, tag)
    num_tables = woff[12, 2].unpack1('n')
    num_tables.times do |index|
      position = 44 + (index * 20)
      return position if woff[position, 4] == tag
    end
    raise "no #{tag} table in the WOFF directory"
  end

  describe '.open' do
    it 'opens file paths' do
      font = described_class.open(test_font('DejaVuSans', :woff))
      expect(font.name.font_name.first).to eq('DejaVu Sans')
    end

    it 'opens IO objects' do
      File.open(test_font('DejaVuSans', :woff), 'rb') do |io|
        font = described_class.open(io)
        expect(font.name.font_name.first).to eq('DejaVu Sans')
      end
    end

    it 'is used by TTFunk::File.open for WOFF content' do
      font = TTFunk::File.open(test_font('DejaVuSans', :woff))
      expect(font).to be_a(described_class)
    end

    it 'raises an error for non-WOFF content' do
      expect { described_class.new('not a font at all') }
        .to raise_error(TTFunk::Error, /not a WOFF file/)
    end
  end

  describe 'font tables' do
    let!(:font) { described_class.open(test_font('DejaVuSans', :woff)) }
    let!(:ttf) { TTFunk::File.open(test_font('DejaVuSans')) }

    it 'exposes the same tables as the equivalent SFNT font' do
      expect(font.directory.tables.keys.sort)
        .to eq(ttf.directory.tables.keys.sort)
    end

    it 'reads table data' do
      expect(font.ascent).to eq(1556)
      expect(font.descent).to eq(-492)
      expect(font.bbox).to eq([-2090, -850, 3442, 2389])
    end

    it 'preserves the scaler type' do
      expect(font.directory.scaler_type).to eq(0x00010000)
      expect(font.flavor).to eq(0x00010000)
    end

    it 'can be subset' do
      subset = TTFunk::Subset::Unicode.new(font)
      encoded = subset.encode

      subset_font = TTFunk::File.open(StringIO.new(encoded))
      expect(subset_font.name.font_name.first).to eq('DejaVu Sans')
    end
  end

  describe 'container attributes' do
    let!(:font) { described_class.open(test_font('DejaVuSans', :woff)) }

    it 'exposes the WOFF version' do
      expect(font.major_version).to eq(1)
      expect(font.minor_version).to eq(0)
    end

    it 'exposes decompressed metadata' do
      expect(font.metadata).to include('<metadata version="1.0">')
    end

    it 'exposes private data' do
      expect(font.private_data)
        .to eq("TTFunk WOFF spec private data\x00\x01\x02")
    end

    it 'keeps metadata and private data out of the font tables' do
      expect(font.directory.tables.keys).to all(match(/\A.{4}\z/))
      expect(font.directory.tables.size).to eq(19)
    end

    it 'returns nil for missing metadata and private data' do
      tables = { 'head' => 'h' * 54, 'name' => 'n' * 32 }
      font = described_class.new(build_woff(tables))

      expect(font.metadata).to be_nil
      expect(font.private_data).to be_nil
    end
  end

  describe 'reconstructed SFNT' do
    let!(:font) { described_class.open(test_font('DejaVuSans', :woff)) }
    let!(:sfnt) { font.contents.tap(&:rewind).read }

    it 'has a valid whole-font checksum' do
      expect(sfnt.unpack('N*').sum & 0xFFFF_FFFF).to eq(0xB1B0AFBA)
    end

    it 'has 4-byte aligned table offsets' do
      font.directory.tables.each_value do |info|
        expect(info[:offset] % 4).to eq(0)
      end
    end

    it 'has valid table checksums' do
      font.directory.tables.each do |tag, info|
        data = sfnt[info[:offset], info[:length]]
        # head checksum is computed with checkSumAdjustment set to zero
        data[8, 4] = "\0\0\0\0" if tag == 'head'
        checksum = data.ljust((data.bytesize + 3) & ~3, "\0")
          .unpack('N*').sum & 0xFFFF_FFFF
        expect(checksum).to eq(info[:checksum]), "checksum mismatch for #{tag}"
      end
    end
  end

  describe 'validation' do
    it 'reports the tag of overlapping tables' do
      tables = { 'head' => 'h' * 64, 'name' => 'n' * 64 }
      woff = build_woff(tables)
      head_position = woff_entry_position(woff, 'head')
      name_position = woff_entry_position(woff, 'name')
      head_offset = woff[head_position + 4, 4].unpack1('N')
      # move the name table into the middle of the head table data
      woff[name_position + 4, 4] = [head_offset + 1].pack('N')

      expect { described_class.new(woff) }
        .to raise_error(TTFunk::Error, /overlaps.*"name"/)
    end

    it 'reports the tag of a table overlapping the directory' do
      tables = { 'head' => 'h' * 64, 'name' => 'n' * 64 }
      woff = build_woff(tables)
      head_position = woff_entry_position(woff, 'head')
      woff[head_position + 4, 4] = [20].pack('N')

      expect { described_class.new(woff) }
        .to raise_error(TTFunk::Error, /"head".*overlaps the table directory/)
    end

    it 'reports the tag of a table with a decompressed length mismatch' do
      tables = { 'head' => 'h' * 64, 'name' => 'n' * 64 }
      woff = build_woff(tables)
      name_position = woff_entry_position(woff, 'name')
      orig_length = woff[name_position + 12, 4].unpack1('N')
      woff[name_position + 12, 4] = [orig_length + 4].pack('N')

      expect { described_class.new(woff) }
        .to raise_error(TTFunk::Error, /"name".*decompressed/)
    end

    it 'reports the tag of a table with a checksum mismatch' do
      tables = { 'head' => 'h' * 64, 'name' => 'n' * 64 }
      woff = build_woff(tables)
      name_position = woff_entry_position(woff, 'name')
      woff[name_position + 16, 4] = [0xDEADBEEF].pack('N')

      expect { described_class.new(woff) }
        .to raise_error(TTFunk::Error, /"name".*checksum mismatch/)
    end
  end
end
