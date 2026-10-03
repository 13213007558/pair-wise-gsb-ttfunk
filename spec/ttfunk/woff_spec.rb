# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::WOFF do
  let(:ttf_data) { File.binread(test_font('DejaVuSans')) }
  let(:ttf) { TTFunk::File.open(test_font('DejaVuSans')) }
  let(:tables) do
    ttf.directory.tables.to_h do |tag, _info|
      [tag, TTFunk::Table::Simple.new(ttf, tag).raw]
    end
  end
  let(:woff_data) { WOFFBuilder.new(tables: tables).build }

  def raw_table(font, tag)
    TTFunk::Table::Simple.new(font, tag).raw
  end

  def set_uint32(data, offset, value)
    data.dup.tap { |copy| copy[offset, 4] = [value].pack('N') }
  end

  def set_uint16(data, offset, value)
    data.dup.tap { |copy| copy[offset, 2] = [value].pack('n') }
  end

  def get_uint32(data, offset)
    data.byteslice(offset, 4).unpack1('N')
  end

  # Position of the directory entry field for the entry at +index+.
  def entry_position(index, field_offset)
    44 + (20 * index) + field_offset
  end

  describe '.decode' do
    it 'decodes tables into a regular font object' do
      font = described_class.decode(woff_data)

      expect(font).to be_a(TTFunk::File)
      expect(font.directory.tables.keys.sort).to eq(tables.keys.sort)
      tables.each do |tag, raw|
        expect(raw_table(font, tag)).to eq(raw)
      end
    end

    it 'produces a font whose tables are usable' do
      font = described_class.decode(woff_data)

      expect(font.name.font_name).to include('DejaVu Sans')
      expect(font.ascent).to eq(ttf.ascent)
      expect(font.cmap.unicode.first).not_to be_nil
    end

    it 'reconstructs a byte-identical sfnt for a standard-layout font' do
      font = described_class.decode(woff_data)

      expect(font.contents.string).to eq(ttf_data)
    end

    it 'supports tables stored uncompressed mixed with compressed ones' do
      mixed = WOFFBuilder.new(tables: tables, compress: %w[glyf head]).build
      entries = WOFFBuilder.entries(mixed)

      stored_raw = entries.select { |entry| entry[:comp_length] == entry[:orig_length] }
      stored_compressed = entries - stored_raw
      expect(stored_raw).not_to be_empty
      expect(stored_compressed).not_to be_empty

      font = described_class.decode(mixed)
      tables.each do |tag, raw|
        expect(raw_table(font, tag)).to eq(raw)
      end
    end

    it 'preserves metadata, private data, and version' do
      data = WOFFBuilder.new(
        tables: tables,
        metadata: '<?xml version="1.0"?><metadata><text>hello</text></metadata>',
        private_data: "priv\x00ate".b,
        version: [2, 5],
      ).build

      font = described_class.decode(data)
      expect(font.woff_metadata).to eq('<?xml version="1.0"?><metadata><text>hello</text></metadata>')
      expect(font.woff_private).to eq("priv\x00ate".b)
      expect(font.woff_version).to eq([2, 5])
    end

    it 'reports nil for absent metadata and private data' do
      font = described_class.decode(woff_data)

      expect(font.woff_metadata).to be_nil
      expect(font.woff_private).to be_nil
    end

    it 'raises a container error for a bad signature' do
      corrupt = woff_data.dup
      corrupt[0, 4] = 'wOOF'

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /signature/)
    end

    it 'raises a container error for a truncated header' do
      expect { described_class.decode(woff_data.byteslice(0, 30)) }
        .to raise_error(TTFunk::WOFF::ContainerError, /too short/)
    end

    it 'raises a container error when the length field does not match the file size' do
      corrupt = set_uint32(woff_data, 8, woff_data.bytesize + 4)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /length mismatch/)
    end

    it 'raises a container error when the reserved field is not zero' do
      corrupt = set_uint16(woff_data, 14, 1)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /reserved/)
    end

    it 'raises a container error when the directory extends past end of file' do
      corrupt = set_uint16(woff_data, 12, 60_000)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /directory/)
    end

    it 'raises a container error for duplicate table tags' do
      entries = WOFFBuilder.entries(woff_data)
      corrupt = woff_data.dup
      corrupt[entry_position(1, 0), 4] = entries[0][:tag]

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /duplicate/)
    end

    it 'raises a container error when compressed length exceeds original length' do
      entries = WOFFBuilder.entries(woff_data)
      index = entries.index { |entry| entry[:comp_length] < entry[:orig_length] }
      corrupt = set_uint32(woff_data, entry_position(index, 8), entries[index][:orig_length] + 4)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /compressed length exceeds/)
    end

    it 'raises a container error for unaligned table data' do
      entries = WOFFBuilder.entries(woff_data)
      corrupt = set_uint32(woff_data, entry_position(0, 4), entries[0][:offset] + 2)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /4-byte aligned/)
    end

    it 'raises a container error for overlapping data blocks' do
      entries = WOFFBuilder.entries(woff_data)
      corrupt = set_uint32(woff_data, entry_position(1, 4), entries[0][:offset])

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /overlaps/)
    end

    it 'raises a container error when a table extends past end of file' do
      entries = WOFFBuilder.entries(woff_data)
      corrupt = set_uint32(woff_data, entry_position(0, 4), (woff_data.bytesize + 3) & ~3)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /past end of file/)
    end

    it 'raises a container error when the total sfnt size does not add up' do
      total = get_uint32(woff_data, 16)
      corrupt = set_uint32(woff_data, 16, total + 4)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /total sfnt size/)
    end

    it 'raises a container error for a truncated zlib stream' do
      entries = WOFFBuilder.entries(woff_data)
      index = entries.index { |entry| entry[:comp_length] < entry[:orig_length] }
      corrupt = set_uint32(woff_data, entry_position(index, 8), entries[index][:comp_length] - 2)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /truncated|corrupt/)
    end

    it 'raises a container error for corrupt zlib data' do
      entries = WOFFBuilder.entries(woff_data)
      entry = entries.find { |item| item[:comp_length] < item[:orig_length] }
      corrupt = woff_data.dup
      corrupt.setbyte(entry[:offset] + 2, corrupt.getbyte(entry[:offset] + 2) ^ 0xFF)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError)
    end

    it 'raises a container error when decompressed length does not match' do
      entries = WOFFBuilder.entries(woff_data)
      index = entries.index { |entry| entry[:comp_length] < entry[:orig_length] }
      corrupt = set_uint32(woff_data, entry_position(index, 12), entries[index][:orig_length] + 4)
      total = get_uint32(woff_data, 16)
      corrupt = set_uint32(corrupt, 16, total + 4)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /decompressed to/)
    end

    it 'raises a container error for a table checksum mismatch' do
      entries = WOFFBuilder.entries(woff_data)
      corrupt = set_uint32(woff_data, entry_position(0, 16), entries[0][:checksum] ^ 1)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::ContainerError, /checksum mismatch/)
    end

    it 'refuses to decompress past the size limit' do
      entries = WOFFBuilder.entries(woff_data)
      index = entries.index { |entry| entry[:comp_length] < entry[:orig_length] }
      forged_length = 200_000_000
      corrupt = set_uint32(woff_data, entry_position(index, 12), forged_length)
      total = get_uint32(woff_data, 16)
      delta = forged_length - ((entries[index][:orig_length] + 3) & ~3)
      corrupt = set_uint32(corrupt, 16, total + delta)

      expect { described_class.decode(corrupt, max_decompressed_size: 1024 * 1024) }
        .to raise_error(TTFunk::WOFF::ContainerError, /exceeds the limit/)
    end

    it 'raises a font data error for an unsupported sfnt flavor' do
      corrupt = set_uint32(woff_data, 4, 0xDEAD_BEEF)

      expect { described_class.decode(corrupt) }
        .to raise_error(TTFunk::WOFF::FontDataError, /flavor/)
    end

    it 'distinguishes container errors from font data errors' do
      expect(TTFunk::WOFF::ContainerError.ancestors).to include(TTFunk::Error)
      expect(TTFunk::WOFF::FontDataError.ancestors).to include(TTFunk::Error)
      expect(TTFunk::WOFF::ContainerError).not_to eq(TTFunk::WOFF::FontDataError)
    end
  end

  describe '.open' do
    it 'reads a WOFF file from an IO' do
      font = described_class.open(StringIO.new(woff_data))

      expect(font).to be_a(TTFunk::File)
      expect(font.directory.tables.keys.sort).to eq(tables.keys.sort)
    end
  end

  describe '.woff?' do
    it 'recognizes WOFF data' do
      expect(described_class.woff?(woff_data)).to be(true)
      expect(described_class.woff?(ttf_data)).to be(false)
    end
  end

  describe 'TTFunk::File.open' do
    it 'auto-detects WOFF containers' do
      font = TTFunk::File.open(StringIO.new(woff_data))

      expect(font).to be_a(TTFunk::File)
      expect(font.name.font_name).to include('DejaVu Sans')
    end

    it 'still opens plain sfnt fonts' do
      font = TTFunk::File.open(StringIO.new(ttf_data))

      expect(font.name.font_name).to include('DejaVu Sans')
    end
  end

  describe 'WOFF -> TTF -> WOFF round trip' do
    it 'keeps decompressed table contents identical' do
      font1 = TTFunk::File.open(StringIO.new(woff_data))
      ttf_bytes = font1.contents.string
      font2 = TTFunk::File.open(StringIO.new(ttf_bytes))
      woff2 = TTFunk::WOFFEncoder.new(font2).encode
      font3 = TTFunk::File.open(StringIO.new(woff2))

      expect(font3.directory.tables.keys.sort).to eq(font1.directory.tables.keys.sort)
      font1.directory.tables.each_key do |tag|
        expect(raw_table(font3, tag)).to eq(raw_table(font1, tag))
      end
    end

    it 'produces a stable sfnt reconstruction' do
      font1 = described_class.decode(woff_data)
      font2 = described_class.decode(TTFunk::WOFFEncoder.new(font1).encode)

      expect(font2.contents.string).to eq(font1.contents.string)
    end
  end
end
