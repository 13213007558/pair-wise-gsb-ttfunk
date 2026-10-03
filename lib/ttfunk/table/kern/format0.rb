# frozen_string_literal: true

require_relative '../../reader'

module TTFunk
  class Table
    class Kern
      # Format 0 kerning subtable.
      class Format0
        include Reader

        # Subtable attributes.
        # @return [Hash{Symbol => any}]
        attr_reader :attributes

        # Kerning pairs.
        # @return [Hash{Array(Integer, Integer) => Integer}]
        attr_reader :pairs

        # @param attributes [Hash{Symbol => any}]
        def initialize(attributes = {})
          @attributes = attributes

          # version 0 data starts at the pair search range, with numPairs 6
          # words in; version 1 data starts at numPairs after its 8-byte
          # header.
          if (attributes[:header_size] || 6) == 8
            num_pairs, *pairs = attributes.delete(:data).unpack('nx6n*')
          else
            num_pairs, *pairs = attributes.delete(:data).unpack('nx6n*')
          end

          @pairs = {}
          num_pairs.times do |i|
            # sanity check, in case there's a bad length somewhere
            break if (i * 3) + 2 > pairs.length

            left = pairs[i * 3]
            right = pairs[(i * 3) + 1]
            value = to_signed(pairs[(i * 3) + 2])
            @pairs[[left, right]] = value
          end
        end

        # Is this vertical kerning?
        # @return [Boolean]
        def vertical?
          @attributes[:vertical]
        end

        # Is this horizontal kerning?
        # @return [Boolean]
        def horizontal?
          !vertical?
        end

        # Is this cross-stream kerning?
        # @return [Boolean]
        def cross_stream?
          @attributes[:cross]
        end

        # Do values of this subtable replace earlier subtables?
        # @return [Boolean]
        def override?
          @attributes[:override]
        end

        # Kerning value for the given glyph pair, in font units.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Integer]
        def kerning_for(left_glyph, right_glyph)
          pairs.fetch([left_glyph, right_glyph], 0)
        end

        # Does this subtable list the given glyph pair?
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Boolean]
        def covers?(left_glyph, right_glyph)
          pairs.key?([left_glyph, right_glyph])
        end

        # Recode this subtable using the specified mapping.
        #
        # @param mapping [Hash{Integer => Integer}] keys are new glyph IDs,
        #   values are old glyph IDs
        # @return [String]
        def recode(mapping)
          subset = []
          pairs.each do |(left, right), value|
            if mapping[left] && mapping[right]
              subset << [mapping[left], mapping[right], value]
            end
          end

          return if subset.empty?

          num_pairs = subset.length
          search_range = 2 * (2**Integer(Math.log(num_pairs) / Math.log(2)))
          entry_selector = Integer(Math.log(search_range / 2) / Math.log(2))
          range_shift = (2 * num_pairs) - search_range

          header =
            if (attributes[:header_size] || 6) == 8
              [
                (num_pairs * 6) + 22,
                attributes[:coverage],
                attributes.fetch(:tuple_index, 0),
              ].pack('Nnn')
            else
              [
                attributes[:version],
                (num_pairs * 6) + 14,
                attributes[:coverage],
              ].pack('n3')
            end

          header +
            [
              num_pairs,
              search_range,
              entry_selector,
              range_shift,
              subset,
            ].flatten.pack('n*')
        end
      end
    end
  end
end
