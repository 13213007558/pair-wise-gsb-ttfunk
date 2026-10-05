# frozen_string_literal: true

require_relative '../../reader'
require_relative '../cbdt/metrics'

module TTFunk
  class Table
    class Cblc < Table
      # CBLC index subtable. It maps glyph IDs to locations of the glyph
      # bitmap data in the CBDT table.
      class IndexSubTable
        include Reader

        # Byte length of the index subtable header.
        HEADER_LENGTH = 8

        # Location of glyph bitmap data in the CBDT table.
        #
        # @!attribute [rw] offset
        #   Offset of the glyph data from the beginning of the CBDT table.
        #   @return [Integer]
        # @!attribute [rw] length
        #   Length of the glyph data in bytes.
        #   @return [Integer]
        # @!attribute [rw] metrics
        #   Glyph metrics for index formats that store them in the CBLC
        #   table, +nil+ otherwise.
        #   @return [TTFunk::Table::Cbdt::BigMetrics, nil]
        Location = Struct.new(:offset, :length, :metrics)

        # Index subtable format.
        # @return [Integer]
        attr_reader :index_format

        # Format of the glyph data in the CBDT table.
        # @return [Integer]
        attr_reader :image_format

        # Offset of the glyph data from the beginning of the CBDT table.
        # @return [Integer]
        attr_reader :image_data_offset

        # Index of the first glyph in this subtable.
        # @return [Integer]
        attr_reader :first_glyph_index

        # Index of the last glyph in this subtable.
        # @return [Integer]
        attr_reader :last_glyph_index

        # @param table [TTFunk::Table::Cblc]
        # @param offset [Integer] offset of the subtable from the beginning
        #   of the file
        # @param first_glyph_index [Integer]
        # @param last_glyph_index [Integer]
        def initialize(table, offset, first_glyph_index, last_glyph_index)
          @file = table.file
          @table = table
          @offset = offset
          @first_glyph_index = first_glyph_index
          @last_glyph_index = last_glyph_index

          parse!
        end

        # Does this subtable cover the glyph?
        #
        # @param glyph_id [Integer]
        # @return [Boolean]
        def covers?(glyph_id)
          (first_glyph_index..last_glyph_index).cover?(glyph_id)
        end

        # Find the location of the glyph bitmap data in the CBDT table.
        #
        # @param glyph_id [Integer]
        # @return [Location, nil] glyph data location or +nil+ if the glyph
        #   has no bitmap in this subtable
        # @raise [TTFunk::Error] on malformed font data
        def location_for(glyph_id)
          return nil unless covers?(glyph_id)

          case index_format
          when 1 then variable_metrics_location(glyph_id, 4)
          when 2 then constant_metrics_location(glyph_id)
          when 3 then variable_metrics_location(glyph_id, 2)
          when 4 then sparse_variable_metrics_location(glyph_id)
          when 5 then sparse_constant_metrics_location(glyph_id)
          end
        end

        private

        def parse!
          assert_within_table!(@offset, HEADER_LENGTH)

          parse_from(@offset) do
            @index_format, @image_format, @image_data_offset = read(8, 'n2N')
          end

          unless (1..5).cover?(@index_format)
            raise TTFunk::Error,
              "unsupported CBLC index subtable format: #{@index_format}"
          end
        end

        # Formats 1 and 3: consecutive glyphs with an array of offsets
        # (4-byte and 2-byte offsets respectively).
        def variable_metrics_location(glyph_id, unit)
          offset_count = last_glyph_index - first_glyph_index + 2
          array_offset = @offset + HEADER_LENGTH
          assert_within_table!(array_offset, offset_count * unit)

          glyph_offset = array_offset + ((glyph_id - first_glyph_index) * unit)
          offset1, offset2 =
            parse_from(glyph_offset) { read(2 * unit, unit == 4 ? 'N2' : 'n2') }

          build_location(offset1, offset2)
        end

        # Format 2: consecutive glyphs of the same size with shared metrics.
        def constant_metrics_location(glyph_id)
          image_size, metrics = constant_metrics_data

          Location.new(
            image_data_offset + ((glyph_id - first_glyph_index) * image_size),
            image_size,
            metrics,
          )
        end

        # Format 4: sparse glyphs with 4-byte offsets.
        def sparse_variable_metrics_location(glyph_id)
          pairs, end_offset = sparse_code_offset_pairs
          pair_index = pairs.index { |code, _| code == glyph_id }
          return nil if pair_index.nil?

          offset1 = pairs[pair_index][1]
          offset2 =
            if pair_index + 1 < pairs.length
              pairs[pair_index + 1][1]
            else
              end_offset
            end

          build_location(offset1, offset2)
        end

        # Format 5: sparse glyphs of the same size with shared metrics.
        def sparse_constant_metrics_location(glyph_id)
          image_size, metrics, glyph_ids = sparse_constant_metrics_data
          glyph_index = glyph_ids.index(glyph_id)
          return nil if glyph_index.nil?

          Location.new(
            image_data_offset + (glyph_index * image_size),
            image_size,
            metrics,
          )
        end

        def build_location(offset1, offset2)
          return nil if offset1 == offset2

          if offset2 < offset1
            raise TTFunk::Error, 'invalid glyph data offsets in CBLC table'
          end

          Location.new(image_data_offset + offset1, offset2 - offset1, nil)
        end

        def constant_metrics_data
          @constant_metrics_data ||= parse_from(@offset + HEADER_LENGTH) {
            assert_within_table!(@offset + HEADER_LENGTH, 12)
            image_size = read(4, 'N').first
            metrics = Cbdt::BigMetrics.from_bytes(io.read(8))
            [image_size, metrics]
          }
        end

        def sparse_code_offset_pairs
          @sparse_code_offset_pairs ||= parse_from(@offset + HEADER_LENGTH) {
            assert_within_table!(@offset + HEADER_LENGTH, 4)
            num_glyphs = read(4, 'N').first
            assert_within_table!(@offset + HEADER_LENGTH, 4 + (num_glyphs * 6) + 4)

            pairs = Array.new(num_glyphs) { read(6, 'nN') }
            end_offset = read(4, 'N').first
            [pairs, end_offset]
          }
        end

        def sparse_constant_metrics_data
          @sparse_constant_metrics_data ||=
            parse_from(@offset + HEADER_LENGTH) {
              assert_within_table!(@offset + HEADER_LENGTH, 16)
              image_size = read(4, 'N').first
              metrics = Cbdt::BigMetrics.from_bytes(io.read(8))
              num_glyphs = read(4, 'N').first
              assert_within_table!(
                @offset + HEADER_LENGTH,
                16 + (num_glyphs * 2),
              )
              glyph_ids = read(num_glyphs * 2, "n#{num_glyphs}")
              [image_size, metrics, glyph_ids]
            }
        end

        def assert_within_table!(position, size)
          if position < @table.offset ||
              position + size > @table.offset + @table.length
            raise TTFunk::Error, 'CBLC index subtable data is out of bounds'
          end
        end
      end
    end
  end
end
