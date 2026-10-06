# frozen_string_literal: true

require_relative '../table'
require_relative 'variation/tuple_variation'

module TTFunk
  class Table
    # Glyph Variations (`gvar`) table. Holds per-glyph TrueType outline and
    # phantom-point deltas across the variation space.
    #
    # https://learn.microsoft.com/en-us/typography/opentype/spec/gvar
    class Gvar < Table
      include Variation::TupleVariation

      TAG = 'gvar'

      TupleDecoder = Variation::TupleVariation
      private_constant :TupleDecoder

      # @return [Integer] table version.
      attr_reader :version

      # @return [Integer] number of glyphs with variation data.
      attr_reader :glyph_count

      # @return [Array<Hash{String => Float}>] shared (global) peak tuples.
      attr_reader :shared_tuples

      # Get the decoded tuple variations of a glyph.
      #
      # @param glyph_id [Integer]
      # @param point_count [Integer] number of points of the glyph including
      #   the four phantom points. Composite glyphs use +component_count + 4+
      #   points, one translation pseudo-point per component.
      # @return [Array<Variation::TupleVariation::Variation>]
      def for(glyph_id, point_count)
        @cache[glyph_id] ||=
          begin
            start = glyph_offset(glyph_id)
            finish = glyph_offset(glyph_id + 1)

            if start >= finish
              []
            else
              decode_glyph(
                raw[@variation_data_offset + start, finish - start],
                point_count
              )
            end
          end
      end

      private

      def tag
        TAG
      end

      def parse!
        data = raw

        @version = data[0, 2].unpack1('n')
        # data[2, 2] is reserved
        @axis_count = data[4, 2].unpack1('n')
        shared_tuple_count = data[6, 2].unpack1('n')
        shared_tuple_offset = data[8, 4].unpack1('N')
        @glyph_count = data[12, 2].unpack1('n')
        @flags = data[14, 2].unpack1('n')
        glyph_variation_data_offset = data[16, 4].unpack1('N')

        @short_offsets = (@flags & 1).zero?
        @variation_data_offset = glyph_variation_data_offset

        @shared_tuples = []
        position = shared_tuple_offset
        shared_tuple_count.times do
          tuple, position =
            read_shared_tuple(data, position)
          @shared_tuples << tuple
        end

        @cache = {}
      end

      def short_offsets?
        @short_offsets
      end

      def glyph_offset(index)
        offset_table_start = 20

        if short_offsets?
          raw[offset_table_start + index * 2, 2].unpack1('n') * 2
        else
          raw[offset_table_start + index * 4, 4].unpack1('N')
        end
      end

      def decode_glyph(glyph_data, point_count)
        tuple_count = glyph_data[0, 2].unpack1('n')
        offset_to_data = glyph_data[2, 2].unpack1('n')

        TupleDecoder.decode(
          glyph_data, 0, 4, offset_to_data, point_count,
          file.fvar.axes.map(&:tag), @shared_tuples, TAG
        ).tap do |variations|
          raise Error, 'gvar tuple count mismatch' unless
            variations.length == (tuple_count & TUPLE_COUNT_MASK)
        end
      end

      def read_shared_tuple(data, position)
        tuple = {}
        file.fvar.axes.each do |axis|
          value = data[position, 2].unpack1('n')
          value -= 0x10000 if value >= 0x8000
          tuple[axis.tag] = value / 16_384.0
          position += 2
        end
        [tuple, position]
      end
    end
  end
end
