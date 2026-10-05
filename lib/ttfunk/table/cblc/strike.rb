# frozen_string_literal: true

require_relative '../../reader'
require_relative 'line_metrics'
require_relative 'index_sub_table'

module TTFunk
  class Table
    class Cblc < Table
      # A single bitmap strike (a bitmapSizeTable record in the CBLC table).
      # A strike contains bitmaps for a range of glyphs at one ppem size and
      # bit depth.
      class Strike
        include Reader

        # Byte length of a bitmapSizeTable record.
        RECORD_LENGTH = 48

        # CBLC table this strike is in.
        # @return [TTFunk::Table::Cblc]
        attr_reader :table

        # Strike index in the CBLC table.
        # @return [Integer]
        attr_reader :index

        # Index of the first glyph in this strike.
        # @return [Integer]
        attr_reader :start_glyph_index

        # Index of the last glyph in this strike.
        # @return [Integer]
        attr_reader :end_glyph_index

        # Horizontal pixels-per-em.
        # @return [Integer]
        attr_reader :ppem_x

        # Vertical pixels-per-em.
        # @return [Integer]
        attr_reader :ppem_y

        # Bit depth of the bitmaps.
        # @return [Integer]
        attr_reader :bit_depth

        # Strike flags.
        # @return [Integer]
        attr_reader :flags

        # Color palette reference.
        # @return [Integer]
        attr_reader :color_ref

        # Horizontal line metrics.
        # @return [TTFunk::Table::Cblc::LineMetrics]
        attr_reader :hori

        # Vertical line metrics.
        # @return [TTFunk::Table::Cblc::LineMetrics]
        attr_reader :vert

        # @param table [TTFunk::Table::Cblc]
        # @param index [Integer] strike index
        def initialize(table, index)
          @file = table.file
          @table = table
          @index = index

          parse!
        end

        # Nominal strike size in pixels-per-em.
        #
        # @return [Integer]
        def ppem
          ppem_x
        end

        # Does this strike contain bitmaps for the glyph?
        #
        # @param glyph_id [Integer]
        # @return [Boolean]
        def covers?(glyph_id)
          (start_glyph_index..end_glyph_index).cover?(glyph_id)
        end

        # Index subtables of this strike.
        #
        # @return [Array<TTFunk::Table::Cblc::IndexSubTable>]
        def index_subtables
          @index_subtables ||= parse_index_subtables
        end

        # Get the bitmap for the glyph from this strike.
        #
        # @param glyph_id [Integer]
        # @return [TTFunk::Table::Cbdt::Glyph, nil] the glyph bitmap or +nil+
        #   if the glyph has no bitmap in this strike
        # @raise [TTFunk::Error] on malformed font data
        def bitmap_for(glyph_id)
          return nil unless covers?(glyph_id)

          subtable = index_subtables.find { |sub| sub.covers?(glyph_id) }
          return nil if subtable.nil?

          location = subtable.location_for(glyph_id)
          return nil if location.nil?

          cbdt = @file.cbdt

          if cbdt.nil? || !cbdt.exists?
            raise TTFunk::Error, 'CBDT table is missing'
          end

          cbdt.glyph(
            subtable.image_format,
            location.offset,
            location.length,
            glyph_id: glyph_id,
            metrics: location.metrics,
          )
        end

        private

        def parse!
          record_offset = @table.offset + 8 + (@index * RECORD_LENGTH)
          assert_within_table!(record_offset, RECORD_LENGTH)

          parse_from(record_offset) do
            @index_sub_table_array_offset, @index_tables_size,
              @number_of_index_subtables, @color_ref = read(16, 'N4')
            @hori = LineMetrics.from_bytes(io.read(LineMetrics::BYTE_LENGTH))
            @vert = LineMetrics.from_bytes(io.read(LineMetrics::BYTE_LENGTH))
            @start_glyph_index, @end_glyph_index,
              @ppem_x, @ppem_y, @bit_depth, @flags = read(8, 'n2C4')
          end
        end

        def parse_index_subtables
          array_offset = @table.offset + @index_sub_table_array_offset
          assert_within_table!(array_offset, @number_of_index_subtables * 8)

          Array.new(@number_of_index_subtables) do |i|
            first_glyph, last_glyph, subtable_offset =
              parse_from(array_offset + (i * 8)) { read(8, 'n2N') }

            IndexSubTable.new(
              @table,
              array_offset + subtable_offset,
              first_glyph,
              last_glyph,
            )
          end
        end

        def assert_within_table!(position, size)
          if position < @table.offset ||
              position + size > @table.offset + @table.length
            raise TTFunk::Error, 'CBLC strike data is out of bounds'
          end
        end
      end
    end
  end
end
