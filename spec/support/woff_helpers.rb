# frozen_string_literal: true

require 'zlib'

module WoffHelpers
  WOFF_SIGNATURE = 'wOFF'.freeze
  WOFF2_SIGNATURE = 'wOF2'.freeze

  def build_woff(
    font_path = test_font('DejaVuSans'),
    compress: true,
    metadata: nil,
    metadata_offset: nil,
    private_data: nil,
    table_data: {},
    table_stored_data: {},
    table_checksums: {},
    table_lengths: {},
    table_compressed_lengths: {},
    table_offsets: {}
  )
    sfnt = File.binread(font_path)
    directory = TTFunk::File.new(sfnt).directory
    entries = directory.tables.values.map do |entry|
      tag = entry[:tag]
      data = table_data.fetch(tag, sfnt.byteslice(entry[:offset], entry[:length])).b
      compressed_data = deflate(data)
      stored_data = table_stored_data.fetch(
        tag,
        if compress && compressed_data.length < data.length
          compressed_data
        else
          data
        end
      ).b

      {
        tag: tag,
        checksum: table_checksums.fetch(tag, entry[:checksum]),
        data: data,
        stored_data: stored_data,
        length: table_lengths.fetch(tag, data.length),
        compressed_length: table_compressed_lengths.fetch(tag, stored_data.length),
        offset: table_offsets[tag],
      }
    end

    offset = 44 + (entries.length * 20)
    records = []

    entries.each do |entry|
      entry[:offset] ||= offset
      records << [
        entry[:tag],
        entry[:checksum],
        entry[:offset],
        entry[:length],
        entry[:compressed_length],
      ].pack('A4N4')
      offset = [offset, entry[:offset] + entry[:stored_data].length +
        padding(entry[:stored_data].length)].max
    end

    metadata_data = metadata ? deflate(metadata) : nil
    table_end = entries.map { |entry| entry[:offset] + entry[:stored_data].length +
      padding(entry[:stored_data].length) }.max
    metadata_offset = metadata ? (metadata_offset || table_end) : 0
    private_offset =
      if private_data
        metadata ? metadata_offset + metadata_data.length : table_end
      else
        0
      end

    total_size = 12 + (entries.length * 16) +
      entries.sum { |entry| padded_length(entry[:length]) }

    header = [
      WOFF_SIGNATURE,
      directory.scaler_type,
      0,
      entries.length,
      0,
      total_size,
      1,
      0,
      metadata_offset,
      metadata ? metadata.length : 0,
      metadata ? metadata_data.length : 0,
      private_offset,
      private_data ? private_data.length : 0,
    ].pack('A4NNn2Nn2N5')

    body = +''.b
    entries.each do |entry|
      body << entry[:stored_data]
      body << ("\0" * padding(entry[:stored_data].length))
    end
    body << metadata_data if metadata_data
    body << private_data if private_data

    woff = header + records.join + body
    woff[8, 4] = [woff.length].pack('N')
    woff
  end

  def sfnt_checksum(data)
    padded = data.b + ("\0" * ((-data.length) % 4))
    padded.unpack('N*').sum & 0xFFFF_FFFF
  end

  def deflate(data)
    deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
    compressed = deflater.deflate(data, Zlib::FINISH)
    deflater.close
    compressed
  end

  def padded_length(length)
    length + padding(length)
  end

  def padding(length)
    (-length) % 4
  end

  def corrupt_byte(data, offset)
    corrupted = data.b.dup
    corrupted.setbyte(offset, corrupted.getbyte(offset) ^ 0xFF)
    corrupted
  end
end
