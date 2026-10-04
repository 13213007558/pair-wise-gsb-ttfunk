# frozen_string_literal: true

require_relative 'encoded_string'
require_relative 'placeholder'

module TTFunk
  # Encodes a complete, non-variable SFNT font from prepared table data.
  class StaticFontEncoder
    OPTIMAL_TABLE_ORDER = %w[
      head hhea maxp OS/2 hmtx LTSH VDMX hdmx cmap fpgm prep cvt loca glyf
      kern name post gasp PCLT
    ].freeze

    REMOVED_TABLE_TAGS = %w[
      avar CFF2 cvar fvar gvar hdmx HVAR MVAR STAT VVAR DSIG
    ].freeze

    # @param file [TTFunk::File]
    # @param generated_tables [Hash{String => String}]
    def initialize(file, generated_tables)
      @file = file
      @generated_tables = generated_tables
    end

    # @return [String]
    def encode
      font = build_font
      adjustment = (0xB1B0AFBA - checksum(font.unresolved_string)) & 0xFFFFFFFF
      font.resolve_placeholder(:head_checksum, [adjustment].pack('N'))
      font.string
    end

    private

    def tables
      @tables ||= copied_tables.merge(@generated_tables).reject do |tag, _|
        REMOVED_TABLE_TAGS.include?(tag)
      end
    end

      def copied_tables
        @file.directory.tables.each_key.with_object({}) do |tag, result|
          info = @file.directory_info(tag)
          result[tag] = @file.contents.string.byteslice(info[:offset], info[:length])
        end
      end

    def build_font
      raise TTFunk::Error, 'head table is required' unless tables.key?('head')

      font = EncodedString.new
      font << [
        @file.directory.scaler_type,
        tables.length,
        *directory_parameters,
      ].pack('Nn*')

      tables.keys.sort.each do |tag|
        font << [tag, checksum(tables.fetch(tag))].pack('A4N')
        font << Placeholder.new(tag, length: 4)
        font << [tables.fetch(tag).length].pack('N')
      end

      table_order.each do |tag|
        next unless tables.key?(tag)

        font.resolve_placeholder(tag, [font.length].pack('N'))
        if tag == 'head'
          @head_offset = font.length
          head_table = EncodedString.new
          head_table << tables.fetch('head').byteslice(0, 8)
          head_table << Placeholder.new(:head_checksum, length: 4)
          head_table << tables.fetch('head').byteslice(12..)
          font << head_table
        else
          font << tables.fetch(tag)
        end
        font.align!(4)
      end

      font
    end

    def table_order
      OPTIMAL_TABLE_ORDER +
        (tables.keys - ['DSIG'] - OPTIMAL_TABLE_ORDER) +
        ['DSIG']
    end

    def directory_parameters
      power = 2 ** Integer(Math.log2(tables.length))
      [power * 16, Integer(Math.log2(power)), [tables.length * 16 - power * 16, 0].max]
    end

    def checksum(data)
      bytes = data.respond_to?(:unresolved_string) ? data.unresolved_string : data
      padded = bytes.b + ("\0" * ((4 - bytes.bytesize % 4) % 4))
      padded.unpack('N*').sum & 0xFFFF_FFFF
    end
  end
end
