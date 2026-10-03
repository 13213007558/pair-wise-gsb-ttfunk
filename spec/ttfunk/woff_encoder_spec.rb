# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset'

RSpec.describe TTFunk::WOFFEncoder do
  let(:ttf) { TTFunk::File.open(test_font('DejaVuSans')) }
  let(:tables) do
    ttf.directory.tables.to_h do |tag, _info|
      [tag, TTFunk::Table::Simple.new(ttf, tag).raw]
    end
  end

  def raw_table(font, tag)
    TTFunk::Table::Simple.new(font, tag).raw
  end

  # Build a minimal sfnt font from a tag => data hash.
  def sfnt(tables)
    tags = tables.keys.sort
    count = tags.length
    max_power = 2**(count.bit_length - 1)
    header = [
      0x0001_0000, count, max_power * 16, count.bit_length - 1, (count * 16) - (max_power * 16),
    ].pack('Nn4')

    offset = 12 + (16 * count)
    directory = String.new(encoding: Encoding::BINARY)
    body = String.new(encoding: Encoding::BINARY)
    tags.each do |tag|
      data = tables[tag]
      checksum = WOFFBuilder.table_checksum(tag, data)
      directory << [tag, checksum, offset, data.bytesize].pack('a4N3')
      body << data
      body << "\0" * ((4 - (data.bytesize % 4)) % 4)
      offset += (data.bytesize + 3) & ~3
    end

    header + directory + body
  end

  it 'encodes a font that decodes back to identical tables' do
    woff = described_class.new(ttf).encode
    font = TTFunk::WOFF.decode(woff)

    expect(font.directory.tables.keys.sort).to eq(tables.keys.sort)
    tables.each do |tag, raw|
      expect(raw_table(font, tag)).to eq(raw)
    end
  end

  it 'accepts a raw sfnt string' do
    woff = described_class.new(File.binread(test_font('DejaVuSans'))).encode
    font = TTFunk::WOFF.decode(woff)

    expect(font.name.font_name).to include('DejaVu Sans')
  end

  it 'writes a spec-conformant header' do
    woff = described_class.new(ttf).encode

    signature, flavor, length, num_tables, reserved, total_sfnt_size =
      woff.unpack('a4N2n2N')
    expect(signature).to eq('wOFF')
    expect(flavor).to eq(ttf.directory.scaler_type)
    expect(length).to eq(woff.bytesize)
    expect(num_tables).to eq(tables.length)
    expect(reserved).to eq(0)

    expected_sfnt_size = 12 + (16 * tables.length) +
      tables.values.sum { |raw| (raw.bytesize + 3) & ~3 }
    expect(total_sfnt_size).to eq(expected_sfnt_size)
  end

  it 'compresses a table only when it makes it shorter' do
    random = Random.new(1234).bytes(997)
    font = TTFunk::File.new(sfnt('rand' => random, 'name' => 'A' * 1000))

    woff = described_class.new(font).encode
    entries = WOFFBuilder.entries(woff).to_h { |entry| [entry[:tag], entry] }

    expect(entries['rand'][:comp_length]).to eq(997)
    expect(entries['name'][:comp_length]).to be < 1000

    decoded = TTFunk::WOFF.decode(woff)
    expect(raw_table(decoded, 'rand')).to eq(random)
    expect(raw_table(decoded, 'name')).to eq('A' * 1000)
  end

  it 'aligns table data blocks to 4-byte boundaries' do
    font = TTFunk::File.new(
      sfnt('aaaa' => 'x' * 5, 'bbbb' => 'y' * 7, 'cccc' => 'z' * 4),
    )

    woff = described_class.new(font).encode
    WOFFBuilder.entries(woff).each do |entry|
      expect(entry[:offset] % 4).to eq(0)
    end
  end

  it 'records table checksums that survive decoding' do
    woff = described_class.new(ttf).encode

    WOFFBuilder.entries(woff).each do |entry|
      expect(entry[:checksum]).to eq(WOFFBuilder.table_checksum(entry[:tag], tables[entry[:tag]]))
    end
  end

  context 'with metadata and private data' do
    let(:source) do
      data = WOFFBuilder.new(
        tables: tables,
        metadata: '<metadata><text>keep me</text></metadata>',
        private_data: 'private bytes'.b,
        version: [2, 3],
      ).build
      TTFunk::WOFF.decode(data)
    end

    it 'preserves them by default' do
      font = TTFunk::WOFF.decode(described_class.new(source).encode)

      expect(font.woff_metadata).to eq('<metadata><text>keep me</text></metadata>')
      expect(font.woff_private).to eq('private bytes'.b)
      expect(font.woff_version).to eq([2, 3])
    end

    it 'allows explicitly deleting them' do
      font = TTFunk::WOFF.decode(
        described_class.new(source, metadata: nil, private: nil).encode,
      )

      expect(font.woff_metadata).to be_nil
      expect(font.woff_private).to be_nil
    end

    it 'allows replacing them' do
      font = TTFunk::WOFF.decode(
        described_class.new(source, metadata: '<other/>', private: 'new'.b).encode,
      )

      expect(font.woff_metadata).to eq('<other/>')
      expect(font.woff_private).to eq('new'.b)
    end

    it 'allows overriding the version' do
      font = TTFunk::WOFF.decode(described_class.new(source, version: [4, 2]).encode)

      expect(font.woff_version).to eq([4, 2])
    end
  end

  it 'works on a font produced by the subset encoder' do
    subset = TTFunk::Subset.for(ttf, :unicode)
    'Hello, world!'.codepoints.each { |codepoint| subset.use(codepoint) }
    subset_ttf = subset.encode

    woff = described_class.new(TTFunk::File.new(subset_ttf)).encode
    font = TTFunk::File.open(StringIO.new(woff))

    expect(font.name.font_name).to include('DejaVu Sans')
    expect(font.cmap.unicode.first[?H.ord]).not_to be_nil
  end
end
