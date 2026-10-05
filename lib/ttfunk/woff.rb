# frozen_string_literal: true

require 'zlib'

module TTFunk
  # WOFF 1 font container.
  class WOFF
    # WOFF 1 signature.
    SIGNATURE = 'wOFF'.freeze

    # WOFF 2 signature.
    WOFF2_SIGNATURE = 'wOF2'.freeze

    # Load a WOFF 1 font.
    #
    # @overload open(io)
    #   @param io [IO] IO to read the container from.
    #   @return [TTFunk::WOFF]
    # @overload open(path)
    #   @param path [String, Pathname] Path to the container.
    #   @return [TTFunk::WOFF]
    def self.open(io_or_path)
      new(TTFunk::File.verify_and_read(io_or_path))
    end

    # Does the data contain a supported WOFF 1 signature?
    #
    # @param contents [String] binary font data
    # @return [Boolean]
    def self.woff?(contents)
      contents.to_s.start_with?(SIGNATURE)
    end

    # Does the data contain the unsupported WOFF 2 signature?
    #
    # @param contents [String] binary font data
    # @return [Boolean]
    def self.woff2?(contents)
      contents.to_s.start_with?(WOFF2_SIGNATURE)
    end

    # SFNT flavor stored in the WOFF header.
    # @return [Integer]
    attr_reader :flavor

    # Compressed metadata block.
    # @return [String, nil]
    attr_reader :metadata

    # Compressed metadata block exactly as stored in the container.
    # @return [String, nil]
    attr_reader :compressed_metadata

    # Private data block.
    # @return [String, nil]
    attr_reader :private_data

    # @param contents [String] complete WOFF 1 container
    # @param offset [Integer] position at which the container starts
    def initialize(contents, offset = 0)
      contents = contents.to_s
      raise Error, 'WOFF container offset is outside the data' if offset > contents.length

      @contents = contents.byteslice(offset..).to_s.b
      @offset = 0

      parse_header
      parse_table_directory
      validate_layout
      read_optional_blocks
      decode_tables
    end

    # Restore the container as an ordinary SFNT font.
    #
    # @return [String]
    def to_sfnt
      table_count = @tables.length
      search_range = (2**Math.log2(table_count).floor) * 16
      entry_selector = Integer(Math.log2(2**Math.log2(table_count).floor))
      range_shift = (table_count * 16) - search_range

      sfnt = String.new(encoding: Encoding::BINARY)
      sfnt << [
        flavor,
        table_count,
        search_range,
        entry_selector,
        range_shift,
      ].pack('Nn*')

      data_offset = 12 + (table_count * 16)
      ordered_entries = @entries.sort_by { |entry| entry[:tag] }
      table_data = {}

      ordered_entries.each do |entry|
        data = @tables.fetch(entry[:tag])
        table_data[entry[:tag]] = data

        sfnt << [
          entry[:tag],
          table_checksum(entry, data),
          data_offset,
          data.length,
        ].pack('A4N*')

        data_offset += pad(data, 4).length
      end

      ordered_entries.each do |entry|
        sfnt << pad(table_data.fetch(entry[:tag]), 4)
      end

      raise Error, "declared SFNT size for WOFF is #{@total_sfnt_size} bytes, " \
        "but decoded size is #{sfnt.length} bytes" unless sfnt.length == @total_sfnt_size

      apply_checksum_adjustment(sfnt)
      sfnt
    end

    # Open the restored SFNT font.
    #
    # @return [TTFunk::File]
    def to_font
      TTFunk::File.new(to_sfnt)
    end

    private

    def parse_header
      ensure_bytes(@offset + 44, 'WOFF header')
      header = slice(@offset, 44)

      signature, @flavor, @length, table_count, _reserved,
        @total_sfnt_size, _major_version, _minor_version,
        @metadata_offset, @metadata_length, @compressed_metadata_length,
        @private_offset, @private_length = header.unpack('A4NNn2Nn2N5')

      if signature == WOFF2_SIGNATURE
        raise ArgumentError, 'WOFF 2 fonts are not supported'
      end

      unless signature == SIGNATURE
        raise ArgumentError, 'not a WOFF 1 file'
      end

      unless @length == @contents.length
        raise Error, "WOFF length is #{@length} bytes but container is " \
          "#{@contents.length} bytes"
      end

      unless @flavor == 0x00010000 || @flavor == 'OTTO'.unpack1('N')
        raise Error, format('unsupported SFNT flavor 0x%08X', @flavor)
      end

      unless @total_sfnt_size >= 12 + (table_count * 16)
        raise Error, "declared SFNT size #{@total_sfnt_size} is too small for " \
          "#{table_count} table(s)"
      end

      @entries = []
      @table_count = table_count
    end

    def parse_table_directory
      directory_start = @offset + 44
      ensure_bytes(directory_start + (@table_count * 20), 'WOFF table directory')

      @table_count.times do
        record = slice(directory_start + (@entries.length * 20), 20)
        tag, checksum, offset, length, compressed_length = record.unpack('A4N4')

        raise Error, "duplicate font table tag #{tag.inspect}" if @entries.any? { |entry| entry[:tag] == tag }

        @entries << {
          tag: tag,
          checksum: checksum,
          offset: offset,
          length: length,
          compressed_length: compressed_length,
        }
      end

      expected_size = expected_sfnt_size(@table_count)
      unless @total_sfnt_size == expected_size
        raise Error, "declared SFNT size is #{@total_sfnt_size} bytes but " \
          "directory requires #{expected_size} bytes"
      end
    end

    def read_optional_blocks
      @metadata =
        if @metadata_offset.zero? && @metadata_length.zero? && @compressed_metadata_length.zero?
          nil
        else
          read_block('metadata', @metadata_offset, @metadata_length, @compressed_metadata_length)
        end

      @private_data =
        if @private_offset.zero? && @private_length.zero?
          nil
        else
          read_block('private', @private_offset, @private_length, nil)
        end
    end

    def read_block(name, offset, length, compressed_length)
      unless length.positive? && !offset.zero?
        raise Error, "invalid #{name} block offset or length"
      end

      if compressed_length
        unless compressed_length.positive?
          raise Error, "invalid compressed #{name} block length"
        end
      end

      read_length = compressed_length || length
      ensure_bytes(offset + read_length, name)
      data = slice(offset, read_length)

      return data unless compressed_length

      @compressed_metadata = data if name == 'metadata'
      inflate(data, offset, name, length)
    end

    def validate_layout
      table_intervals = @entries.map { |entry| table_interval(entry) }
      validate_block(table_intervals, 'font table')

      optional_blocks = []
      if @metadata_offset.positive?
        optional_blocks << block_interval(
          'metadata',
          @metadata_offset,
          @compressed_metadata_length
        )
      end
      optional_blocks << block_interval('private', @private_offset, @private_length) unless @private_offset.zero?
      validate_block(optional_blocks, 'container block')

      @entries.zip(table_intervals).each do |entry, table|
        validate_table_entry(entry)
        optional_blocks.each do |other|
          next unless overlap?(table, other)

          raise Error, "font table #{entry[:tag].inspect} overlaps #{other[:tag]} block"
        end
      end
    end

    def table_interval(entry)
      {
        tag: entry[:tag],
        offset: entry[:offset],
        length: entry[:compressed_length],
      }
    end

    def block_interval(tag, offset, length)
      { tag: tag, offset: offset, length: length }
    end

    def validate_block(blocks, name)
      blocks.each do |block|
        unless block[:offset].positive?
          raise Error, "#{name} #{block[:tag].inspect} has invalid offset"
        end

        unless block[:length].positive?
          raise Error, "#{name} #{block[:tag].inspect} has invalid length"
        end

        ensure_bytes(block[:offset] + block[:length], name)
        should_align = name == 'font table' || block[:tag] == 'metadata'
        ensure_aligned(block, font_table: name == 'font table') if should_align
      end

      blocks.combination(2).each do |first, second|
        next unless overlap?(first, second)

        if name == 'font table'
          raise Error, "font table #{first[:tag].inspect} overlaps #{second[:tag].inspect}"
        end

        raise Error, "#{name} #{first[:tag]} overlaps #{second[:tag]}"
      end
    end

    def validate_table_entry(entry)
      if entry[:compressed_length] > entry[:length]
        raise Error, "compressed length for font table #{entry[:tag].inspect} " \
          "does not match its uncompressed length"
      end

      unless entry[:length].positive?
        raise Error, "font table #{entry[:tag].inspect} has invalid uncompressed length"
      end

      return if entry[:compressed_length] == entry[:length]

      ensure_bytes(entry[:offset] + entry[:compressed_length], entry[:tag])
    end

    def decode_tables
      @tables = {}

      @entries.each do |entry|
        compressed_data = slice(entry[:offset], entry[:compressed_length])
        data =
          if entry[:compressed_length] == entry[:length]
            compressed_data
          else
            inflate(compressed_data, entry[:offset], entry[:tag], entry[:length])
          end

        actual_checksum = table_checksum(entry, data)
        next if actual_checksum == entry[:checksum]

        raise Error, "checksum mismatch for font table #{entry[:tag].inspect}: " \
          "expected 0x%08X, got 0x%08X" % [entry[:checksum], actual_checksum]
      ensure
        @tables[entry[:tag]] = data if data
      end
    end

    def inflate(data, offset, tag, expected_length)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      inflated = inflater.inflate(data)
      inflater.finish
      inflater.close

      if inflated.length != expected_length
        raise Error, "decompressed length mismatch for #{tag.inspect} at offset " \
          "#{offset}: expected #{expected_length} bytes, got #{inflated.length} bytes"
      end

      inflated
    rescue Zlib::Error => error
      raise Error, "unable to decompress #{tag.inspect} at offset #{offset}: #{error.message}"
    end

    def ensure_aligned(block, font_table:)
      return if (block[:offset] % 4).zero?

      description = font_table ? "font table #{block[:tag].inspect}" : block[:tag]
      raise Error, "#{description} is not four-byte aligned"
    end

    def overlap?(first, second)
      first_end = first[:offset] + first[:length]
      second_end = second[:offset] + second[:length]

      first[:offset] < second_end && second[:offset] < first_end
    end

    def table_checksum(entry, data)
      return checksum(data) unless entry[:tag] == 'head' && data.length >= 12

      adjusted = data.b.dup
      adjusted[8, 4] = [0].pack('N')
      checksum(adjusted)
    end

    def expected_sfnt_size(table_count)
      12 + (table_count * 16) + @entries.sum { |entry| padded_length(entry[:length], 4) }
    end

    def apply_checksum_adjustment(sfnt)
      head = @entries.find { |entry| entry[:tag] == 'head' }
      unless head
        raise Error, "unable to calculate whole-font checksum without a 'head' table"
      end

      data_offset = 12 + (@entries.length * 16)
      head_offset = nil
      @entries.sort_by { |entry| entry[:tag] }.each do |entry|
        if entry[:tag] == 'head'
          head_offset = data_offset
          break
        end

        data_offset += pad(@tables.fetch(entry[:tag]), 4).length
      end

      adjustment_offset = head_offset + 8
      sfnt[adjustment_offset, 4] = [0].pack('N')
      adjustment = (0xB1B0AFBA - checksum(sfnt)) & 0xFFFF_FFFF
      sfnt[adjustment_offset, 4] = [adjustment].pack('N')
    end

    def checksum(data)
      pad(data, 4).unpack('N*').sum & 0xFFFF_FFFF
    end

    def pad(data, width)
      data + ("\0" * (padding_amount(data.length, width)))
    end

    def padded_length(length, width)
      length + padding_amount(length, width)
    end

    def padding_amount(length, width)
      (-length) % width
    end

    def slice(offset, length)
      @contents.byteslice(offset, length).b
    end

    def ensure_bytes(required_length, description)
      return if required_length <= @contents.length

      raise Error, "#{description} extends beyond end of WOFF container"
    end
  end
end
