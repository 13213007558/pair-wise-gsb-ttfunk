# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Kerning (`kern`) table
    class Kern < Table
      # Raised when a kerning subtable in an unsupported format is found.
      class UnsupportedFormatError < Error; end

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
      # @param mapping [Hash{Integer => Integer}] keys are new glyph IDs, values
      #   are old glyph IDs
      # @return [String, nil]
      def self.encode(kerning, mapping)
        return unless kerning.exists? && kerning.tables.any?

        tables = kerning.tables.filter_map { |table| table.recode(mapping) }
        return if tables.empty?

        if kerning.tables.any? { |table| table.attributes[:header_size] == 8 }
          data = tables.join
          [0x00010000, tables.length].pack('NN') + data
        else
          [0, tables.length, tables.join].pack('nnA*')
        end
      end

      # Combined kerning pairs across every subtable.
      #
      # Values of ordinary subtables accumulate. Subtables flagged as
      # overrides replace the accumulated value instead.
      #
      # @param horizontal [Boolean] only combine horizontal subtables when
      #   true
      # @return [Hash{Array(Integer, Integer) => Integer}]
      def pairs(horizontal: false)
        combine do |result, table|
          next if horizontal && !table.horizontal?

          table.pairs.each do |pair, value|
            if table.override? || result[pair].zero?
              result[pair] = value
            else
              result[pair] += value
            end
          end
        end
      end

      # Kerning value for the given glyph pair, in font units.
      #
      # Values of ordinary subtables accumulate. Subtables flagged as
      # overrides replace the accumulated value instead.
      #
      # @param left_glyph [Integer]
      # @param right_glyph [Integer]
      # @param horizontal [Boolean] only consider horizontal subtables when
      #   true
      # @return [Integer]
      def kerning_for(left_glyph, right_glyph, horizontal: true)
        pair = [left_glyph, right_glyph]
        combine do |value, table|
          next if horizontal && !table.horizontal?

          next unless table.covers?(left_glyph, right_glyph)

          table_value = table.kerning_for(left_glyph, right_glyph)
          if table.override? || value[pair].zero?
            value[pair] = table_value
          else
            value[pair] += table_value
          end
        end.fetch(pair, 0)
      end

      private

      def parse!
        @tables = []

        @version = read(2, 'n').first

        if @version == 1 # Mac OS X fonts: version is 0x00010000 as uint32
          version_high = read(2, 'n').first
          @version = (@version << 16) + version_high
          num_tables = read(4, 'N').first
          parse_version_1_tables(num_tables)
        else
          num_tables = read(2, 'n').first
          parse_version_0_tables(num_tables)
        end
      end

      def parse_version_0_tables(_num_tables)
        # It looks like some MS fonts report their kerning subtable lengths
        # wrong. In one case, the length was reported to be some 19366, and yet
        # the table also claimed to hold 14148 pairs (each pair consisting of
        # 6 bytes).  You do the math!
        #
        # We're going to assume that the microsoft fonts hold only a single
        # kerning subtable, which occupies the entire length of the kerning
        # table. Worst case, we lose any other subtables that the font contains,
        # but it's better than reading a truncated kerning table.
        #
        # And what's more, it appears to work. So.
        table_start = io.pos
        table_end = table_start + @length
        num_tables = raw.unpack1('x2n')

        read_count = 0
        while io.pos < table_end
          start = io.pos
          header = io.read(6)
          break if header.nil? || header.length < 6

          version, length, coverage = header.unpack('n*')
          if start + length > table_end || length < 6
            length = table_end - start
          end

          format = coverage >> 8

          data = io.read(length - 6) || ''

          add_table(
            format,
            version: version,
            length: length,
            coverage: coverage,
            header_size: 6,
            data: data,
            vertical: coverage.nobits?(0x1),
            cross: coverage.allbits?(0x4),
            override: coverage.allbits?(0x8),
          )

          io.pos = start + length
          read_count += 1
          break if read_count >= num_tables
        end
      end

      def parse_version_1_tables(num_tables)
        num_tables.times do
          length, coverage, tuple_index = read(8, 'Nnn')
          format = coverage & 0x0FF

          add_table(
            format,
            length: length,
            coverage: coverage,
            header_size: 8,
            tuple_index: tuple_index,
            data: io.read(length - 8),
            vertical: coverage.nobits?(0x8000),
            cross: coverage.allbits?(0x4000),
            variation: coverage.allbits?(0x2000),
            override: coverage.allbits?(0x1000),
          )
        end
      end

      def add_table(format, attributes = {})
        case format
        when 0
          @tables << Kern::Format0.new(attributes)
        when 2
          @tables << Kern::Format2.new(attributes)
        else
          raise(
            UnsupportedFormatError,
            "unsupported kern subtable format: #{format}",
          )
        end
      end

      def combine
        result = Hash.new(0)
        @tables.each { |table| yield(result, table) }
        result
      end
    end
  end
end

require_relative 'kern/format0'
require_relative 'kern/format2'
