# frozen_string_literal: true

require 'zlib'

module TTFunk
  # WOFF 1.0 container support.
  #
  # WOFF is a wrapper around an SFNT font (TrueType/OpenType). Decoding
  # a WOFF file produces a regular {TTFunk::File} so all the usual table
  # reading and subsetting interfaces work on it unchanged.
  module WOFF
    # WOFF file signature.
    SIGNATURE = 'wOFF'

    # WOFF file header length in bytes.
    HEADER_LENGTH = 44

    # WOFF table directory entry length in bytes.
    DIRECTORY_ENTRY_LENGTH = 20

    # Default limit on the total size of decompressed data, in bytes.
    DEFAULT_MAX_DECOMPRESSED_SIZE = 256 * 1024 * 1024

    # Generic WOFF error.
    class Error < TTFunk::Error; end

    # Raised when the WOFF container itself is malformed: bad header,
    # corrupt directory, overlapping or truncated data blocks, checksum
    # mismatches, decompression bombs, and so on.
    class ContainerError < Error; end

    # Raised when the WOFF container is well-formed but the decompressed
    # data is not a usable font.
    class FontDataError < Error; end

    # Recognized SFNT scaler types.
    KNOWN_FLAVORS = [
      0x0001_0000, # TrueType
      0x7472_7565, # 'true'
      0x7479_7031, # 'typ1'
      0x4F54_544F, # 'OTTO'
    ].freeze

    class << self
      # Does the data look like a WOFF file?
      #
      # @param data [String]
      # @return [Boolean]
      def woff?(data)
        data[0, 4] == SIGNATURE
      end

      # Open a WOFF file.
      #
      # @overload open(io, max_decompressed_size: DEFAULT_MAX_DECOMPRESSED_SIZE)
      #   @param io [IO] IO to read the WOFF data from.
      #   @param max_decompressed_size [Integer] limit on the total size of
      #     decompressed data, in bytes
      #   @return [TTFunk::File]
      # @overload open(path, max_decompressed_size: DEFAULT_MAX_DECOMPRESSED_SIZE)
      #   @param path [String, Pathname] path to the WOFF file
      #   @param max_decompressed_size [Integer] limit on the total size of
      #     decompressed data, in bytes
      #   @return [TTFunk::File]
      def open(io_or_path, max_decompressed_size: DEFAULT_MAX_DECOMPRESSED_SIZE)
        decode(
          TTFunk::File.verify_and_read(io_or_path),
          max_decompressed_size: max_decompressed_size,
        )
      end

      # Decode a WOFF container into a font.
      #
      # Container-level problems (bad header, corrupt directory, overlapping
      # or truncated data blocks, checksum mismatches, exceeded decompression
      # limit) raise {TTFunk::WOFF::ContainerError}. Problems with the
      # decompressed font data raise {TTFunk::WOFF::FontDataError} at decode
      # time, or the usual TTFunk errors when individual tables are accessed.
      #
      # @param data [String] binary string containing the WOFF file
      # @param max_decompressed_size [Integer] limit on the total size of
      #   decompressed data, in bytes
      # @return [TTFunk::File]
      # @raise [TTFunk::WOFF::ContainerError]
      # @raise [TTFunk::WOFF::FontDataError]
      def decode(data, max_decompressed_size: DEFAULT_MAX_DECOMPRESSED_SIZE)
        Decoder.new(data, max_decompressed_size: max_decompressed_size).decode
      end

      # SFNT checksum of a piece of data.
      #
      # @param data [String]
      # @return [Integer]
      def checksum(data)
        padding = (4 - (data.bytesize % 4)) % 4
        (data + ("\0" * padding)).unpack('N*').sum & 0xFFFF_FFFF
      end
    end

    # WOFF container decoder.
    # @api private
    class Decoder
      # Compressed data is inflated in chunks of this size so that a forged
      # original length can't trigger a huge allocation.
      INFLATE_CHUNK_SIZE = 16 * 1024

      # @param data [String] binary string containing the WOFF file
      # @param max_decompressed_size [Integer]
      def initialize(data, max_decompressed_size:)
        @data = data
        @max_decompressed_size = max_decompressed_size
      end

      # Decode the container.
      #
      # @return [TTFunk::File]
      def decode
        header = parse_header
        entries = parse_directory(header)
        verify_layout(header, entries)
        verify_decompressed_size(header)
        verify_flavor(header)

        tables = entries.map do |entry|
          data = extract_table(entry)
          verify_checksum(entry, data)
          { tag: entry[:tag], checksum: entry[:checksum], data: data }
        end

        font = build_font(header, tables)
        font.woff_version = [header[:major_version], header[:minor_version]]
        font.woff_metadata = extract_metadata(header)
        font.woff_private = extract_private(header)
        font
      end

      private

      def parse_header
        if @data.bytesize < HEADER_LENGTH
          raise ContainerError,
            "file is too short to be a WOFF file (#{@data.bytesize} bytes)"
        end

        signature, flavor, length, num_tables, reserved,
          total_sfnt_size, major_version, minor_version,
          meta_offset, meta_length, meta_orig_length,
          priv_offset, priv_length = @data.unpack('a4N2n2Nn2N5')

        unless signature == SIGNATURE
          raise ContainerError, 'not a WOFF file (bad signature)'
        end
        unless reserved.zero?
          raise ContainerError,
            "reserved header field must be zero, got #{reserved}"
        end
        unless length == @data.bytesize
          raise ContainerError,
            "WOFF length mismatch: header says #{length} bytes, " +              "file has #{@data.bytesize} bytes"
        end

        {
          flavor: flavor,
          num_tables: num_tables,
          total_sfnt_size: total_sfnt_size,
          major_version: major_version,
          minor_version: minor_version,
          meta_offset: meta_offset,
          meta_length: meta_length,
          meta_orig_length: meta_orig_length,
          priv_offset: priv_offset,
          priv_length: priv_length,
        }
      end

      def parse_directory(header)
        directory_end = HEADER_LENGTH + (header[:num_tables] * DIRECTORY_ENTRY_LENGTH)
        if directory_end > @data.bytesize
          raise ContainerError, 'table directory extends past end of file'
        end

        entries = Array.new(header[:num_tables]) do |i|
          tag, offset, comp_length, orig_length, checksum =
            @data.byteslice(HEADER_LENGTH + (i * DIRECTORY_ENTRY_LENGTH), DIRECTORY_ENTRY_LENGTH)
              .unpack('a4N4')

          if comp_length > orig_length
            raise ContainerError,
              "table #{tag.inspect} compressed length exceeds its original length"
          end
          if (offset % 4).positive?
            raise ContainerError,
              "table #{tag.inspect} data is not 4-byte aligned"
          end

          {
            tag: tag,
            offset: offset,
            comp_length: comp_length,
            orig_length: orig_length,
            checksum: checksum,
          }
        end

        tags = entries.map { |entry| entry[:tag] }
        if tags.uniq.length != tags.length
          raise ContainerError, 'duplicate table tags in directory'
        end

        entries
      end

      def verify_layout(header, entries)
        regions = entries.map { |entry|
          [entry[:offset], entry[:offset] + entry[:comp_length], "table #{entry[:tag].inspect}"]
        }
        if header[:meta_length].positive?
          regions << [header[:meta_offset], header[:meta_offset] + header[:meta_length], 'metadata block']
        end
        if header[:priv_length].positive?
          regions << [header[:priv_offset], header[:priv_offset] + header[:priv_length], 'private data block']
        end

        directory_end = HEADER_LENGTH + (header[:num_tables] * DIRECTORY_ENTRY_LENGTH)
        regions.sort_by!(&:first)
        regions.each_with_index do |(start, stop, name), i|
          if start < directory_end
            raise ContainerError, "#{name} overlaps the WOFF header or directory"
          end
          if stop > @data.bytesize
            raise ContainerError, "#{name} extends past end of file"
          end
          if i.positive? && start < regions[i - 1][1]
            raise ContainerError, "#{name} overlaps #{regions[i - 1][2]}"
          end
        end

        expected = 12 + (16 * header[:num_tables]) +
          entries.sum { |entry| align4(entry[:orig_length]) }
        unless header[:total_sfnt_size] == expected
          raise ContainerError,
            "total sfnt size mismatch: header says #{header[:total_sfnt_size]} bytes, " +              "table directory implies #{expected} bytes"
        end
      end

      def verify_decompressed_size(header)
        total = header[:total_sfnt_size] + header[:meta_orig_length]
        if total > @max_decompressed_size
          raise ContainerError,
            "decompressed size (#{total} bytes) exceeds the limit " +              "of #{@max_decompressed_size} bytes"
        end
      end

      def verify_flavor(header)
        unless KNOWN_FLAVORS.include?(header[:flavor])
          raise FontDataError,
            format('unsupported sfnt flavor 0x%08X', header[:flavor])
        end
      end

      def extract_table(entry)
        data = @data.byteslice(entry[:offset], entry[:comp_length])
        if entry[:comp_length] == entry[:orig_length]
          data
        else
          inflate(data, entry[:orig_length], "table #{entry[:tag].inspect}")
        end
      end

      def verify_checksum(entry, data)
        if entry[:tag] == 'head' && data.bytesize >= 12
          data = data.dup
          data[8, 4] = "\0\0\0\0"
        end
        actual = WOFF.checksum(data)
        unless actual == entry[:checksum]
          raise ContainerError,
            format('checksum mismatch for table %s', entry[:tag].inspect)
        end
      end

      def extract_metadata(header)
        return nil if header[:meta_length].zero?

        data = @data.byteslice(header[:meta_offset], header[:meta_length])
        if header[:meta_length] == header[:meta_orig_length]
          data
        else
          inflate(data, header[:meta_orig_length], 'metadata block')
        end
      end

      def extract_private(header)
        return nil if header[:priv_length].zero?

        @data.byteslice(header[:priv_offset], header[:priv_length])
      end

      def inflate(compressed, expected_length, description)
        inflater = Zlib::Inflate.new
        result = String.new(encoding: Encoding::BINARY)
        offset = 0
        while offset < compressed.bytesize
          result << inflater.inflate(compressed.byteslice(offset, INFLATE_CHUNK_SIZE))
          offset += INFLATE_CHUNK_SIZE
          if result.bytesize > expected_length
            raise ContainerError,
              "#{description} expands past its declared original length"
          end
        end
        result << inflater.finish
        unless inflater.finished?
          raise ContainerError, "truncated compressed data in #{description}"
        end
        inflater.close
        unless result.bytesize == expected_length
          raise ContainerError,
            "#{description} decompressed to #{result.bytesize} bytes, " +              "expected #{expected_length} bytes"
        end
        result
      rescue Zlib::Error => e
        raise ContainerError, "corrupt compressed data in #{description}: #{e.message}"
      end

      def build_font(header, tables)
        tables.sort_by! { |table| table[:tag] }

        count = tables.length
        max_power = count.positive? ? 2**(count.bit_length - 1) : 0
        search_range = max_power * 16
        entry_selector = max_power.positive? ? max_power.bit_length - 1 : 0
        range_shift = (count * 16) - search_range

        offset = 12 + (16 * count)
        offsets = tables.map do |table|
          current = offset
          offset += align4(table[:data].bytesize)
          current
        end

        sfnt = String.new(encoding: Encoding::BINARY)
        sfnt << [header[:flavor], count, search_range, entry_selector, range_shift].pack('Nn4')
        tables.each_with_index do |table, i|
          sfnt << [table[:tag], table[:checksum], offsets[i], table[:data].bytesize].pack('a4N3')
        end

        head_offset = nil
        tables.each_with_index do |table, i|
          head_offset = offsets[i] if table[:tag] == 'head'
          sfnt << table[:data]
          sfnt << "\0" * (align4(table[:data].bytesize) - table[:data].bytesize)
        end

        if head_offset
          head = tables.find { |table| table[:tag] == 'head' }
          if head[:data].bytesize >= 12
            sfnt[head_offset + 8, 4] = "\0\0\0\0"
            adjustment = (0xB1B0_AFBA - WOFF.checksum(sfnt)) & 0xFFFF_FFFF
            sfnt[head_offset + 8, 4] = [adjustment].pack('N')
          end
        end

        TTFunk::File.new(sfnt)
      end

      def align4(length)
        (length + 3) & ~3
      end
    end
  end
end
