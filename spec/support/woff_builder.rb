# frozen_string_literal: true

require 'zlib'

# Minimal WOFF 1.0 container writer used to produce test samples.
# Deliberately independent of TTFunk::WOFFEncoder so that decoding and
# encoding are tested against separately produced bytes.
class WOFFBuilder
  attr_reader :tables, :flavor, :metadata, :private_data, :version, :compress

  # @param tables [Hash{String => String}] table tag => raw table data
  # @param flavor [Integer] sfnt scaler type
  # @param metadata [String, nil] metadata block (stored zlib-compressed)
  # @param private_data [String, nil] private data block (stored as-is)
  # @param version [Array(Integer, Integer)] font version for the header
  # @param compress [:all, Array<String>] candidate tags for zlib
  #   compression; a table is stored compressed only when that makes it
  #   shorter, all other tables are stored uncompressed
  def initialize(tables:, flavor: 0x0001_0000, metadata: nil, private_data: nil, version: [1, 0], compress: :all)
    @tables = tables
    @flavor = flavor
    @metadata = metadata
    @private_data = private_data
    @version = version
    @compress = compress
  end

  # Build the WOFF file.
  #
  # @return [String]
  def build
    entries = tables.keys.sort.map do |tag|
      raw = tables[tag]
      data = raw
      if compress?(tag)
        compressed = Zlib::Deflate.deflate(raw)
        data = compressed if compressed.bytesize < raw.bytesize
      end
      {
        tag: tag,
        data: data,
        orig_length: raw.bytesize,
        checksum: self.class.table_checksum(tag, raw),
      }
    end

    directory_length = 20 * entries.length
    body = String.new(encoding: Encoding::BINARY)
    entries.each do |entry|
      pad4(body)
      entry[:offset] = 44 + directory_length + body.bytesize
      body << entry[:data]
    end

    meta_offset = 0
    meta_length = 0
    meta_orig_length = 0
    if metadata
      compressed_meta = Zlib::Deflate.deflate(metadata)
      pad4(body)
      meta_offset = 44 + directory_length + body.bytesize
      meta_length = compressed_meta.bytesize
      meta_orig_length = metadata.bytesize
      body << compressed_meta
    end

    priv_offset = 0
    priv_length = 0
    if private_data
      pad4(body)
      priv_offset = 44 + directory_length + body.bytesize
      priv_length = private_data.bytesize
      body << private_data
    end

    total_sfnt_size = 12 + (16 * entries.length) +
      entries.sum { |entry| (entry[:orig_length] + 3) & ~3 }

    header = [
      'wOFF',
      flavor,
      44 + directory_length + body.bytesize,
      entries.length,
      0,
      total_sfnt_size,
      version[0],
      version[1],
      meta_offset,
      meta_length,
      meta_orig_length,
      priv_offset,
      priv_length,
    ].pack('a4N2n2Nn2N5')

    directory = entries.map { |entry|
      [entry[:tag], entry[:offset], entry[:data].bytesize, entry[:orig_length], entry[:checksum]]
        .pack('a4N4')
    }.join

    header + directory + body
  end

  # SFNT checksum of a table.
  #
  # @param tag [String]
  # @param data [String]
  # @return [Integer]
  def self.table_checksum(tag, data)
    if tag == 'head' && data.bytesize >= 12
      data = data.dup
      data[8, 4] = "\0\0\0\0"
    end
    padded = data + ("\0" * ((4 - (data.bytesize % 4)) % 4))
    padded.unpack('N*').sum & 0xFFFF_FFFF
  end

  # Parse the table directory of a WOFF file (test helper).
  #
  # @param data [String]
  # @return [Array<Hash>]
  def self.entries(data)
    count = data.byteslice(12, 2).unpack1('n')
    count.times.map do |i|
      tag, offset, comp_length, orig_length, checksum =
        data.byteslice(44 + (20 * i), 20).unpack('a4N4')
      {
        tag: tag,
        offset: offset,
        comp_length: comp_length,
        orig_length: orig_length,
        checksum: checksum,
      }
    end
  end

  private

  def compress?(tag)
    compress == :all || compress.include?(tag)
  end

  def pad4(string)
    string << "\0" * ((4 - (string.bytesize % 4)) % 4)
  end
end
