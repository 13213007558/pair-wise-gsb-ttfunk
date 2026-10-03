# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Kerning (`kern`) table
    class Kern < Table
      # Raised when the font contains a kerning subtable in a format that is
      # not supported. The subtable is not treated as zero kerning.
      class UnsupportedFormatError < StandardError; end

      # Table version
      # @return [Integer]
      attr_reader :version

      # Subtables.
      # @return [Array<TTFunk::Table::Kern::Format0,
      #   TTFunk::Table::Kern::Format2>]
      attr_reader :tables

      # Encode table.
      #
      # @param kerning [TTFunk::Table::Kern]
      # @param mapping [Hash{Integer => Integer}] keys are old glyph IDs,
      #   values are new glyph IDs
      # @return [String, nil]
      def self.encode(kerning, mapping)
        return unless kerning.exists? && kerning.tables.any?

        tables = kerning.tables.filter_map { |table| table.recode(mapping) }
        return if tables.empty?

        [0, tables.length, tables.join].pack('nnA*')
      end

      # Get the accumulated kerning value for a pair of glyph ids.
      #
      # Subtables are consulted in order. Values of non-override subtables
      # are added together; an override subtable replaces the accumulated
      # value instead of contributing to it. Only horizontal subtables are
      # considered.
      #
      # @param left_glyph [Integer]
      # @param right_glyph [Integer]
      # @return [Integer]
      def kerning_for(left_glyph, right_glyph)
        tables.reduce(0) do |value, table|
          next value unless table.horizontal?

          if table.override?
            table.override_value_for(left_glyph, right_glyph) || value
          else
            value + table.kerning_for(left_glyph, right_glyph)
          end
        end
      end

      private

      def parse!
        @version, num_tables = read(4, 'n*')
        @tables = []

        if @version == 1 # Mac OS X fonts
          @version = (@version << 16) + num_tables
          num_tables = read(4, 'N').first
          parse_version_1_tables(num_tables)
        else
          parse_version_0_tables(num_tables)
        end
      end

      def parse_version_0_tables(num_tables)
        table_end = offset + length
        subtable_index = 0

        while subtable_index < num_tables && io.pos < table_end
          subtable_start = io.pos

          _version, subtable_length, coverage = read(6, 'n*')
          format = coverage >> 8

          # Some Microsoft fonts report the length of their (single)
          # kerning subtable incorrectly. Trust a length that stays within
          # the kern table, otherwise consume everything that remains.
          body_length = subtable_length - 6
          if body_length <= 0
            # A missing or zero length is only tolerated for the single
            # (commonly malformed) Microsoft subtable.
            break unless num_tables == 1

            body_length = table_end - io.pos
          elsif (subtable_start + subtable_length) > table_end
            # The declared length overruns the kern table. Clamp it so later
            # subtables of multi-subtable fonts can still be parsed.
            body_length = table_end - io.pos
          end

          data = io.read(body_length)
          add_table(
            format,
            length: subtable_length,
            coverage: coverage,
            data: data,
            vertical: coverage.allbits?(0x1),
            minimum: coverage.allbits?(0x2),
            cross: coverage.allbits?(0x4),
            override: coverage.allbits?(0x8),
          )

          subtable_index += 1
        end
      end

      def parse_version_1_tables(num_tables)
        num_tables.times do
          length, coverage, tuple_index = read(8, 'Nnn')
          format = coverage & 0x0FF
          data = io.read(length - 8)

          if format == 2
            # AAT class-based (format 2) subtables have a state-machine
            # layout different from version 0 and are not supported.
            raise UnsupportedFormatError,
                  'AAT kerning subtable format 2 is not supported'
          end

          add_table(
            format,
            length: length,
            coverage: coverage,
            tuple_index: tuple_index,
            data: data,
            vertical: coverage.nobits?(0x8000),
            cross: coverage.allbits?(0x4000),
            variation: coverage.allbits?(0x2000),
          )
        end
      end

      def add_table(format, attributes = {})
        if format.zero?
          @tables << Kern::Format0.new(attributes)
        elsif format == 2
          @tables << Kern::Format2.new(attributes)
        else
          raise UnsupportedFormatError,
                "kerning subtable format #{format} is not supported"
        end
      end
    end
  end
end

require_relative 'kern/format0'
require_relative 'kern/format2'
