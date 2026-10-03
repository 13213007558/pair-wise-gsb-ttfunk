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

          num_pairs, *pairs = (@attributes[:data] || +'').unpack('nx6n*')

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

        # Do later non-override subtables add to this subtable's values?
        # @return [Boolean]
        def override?
          @attributes[:override]
        end

        # Get the kerning value for the given pair of glyph ids.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Integer]
        def kerning_for(left_glyph, right_glyph)
          pairs.fetch([left_glyph, right_glyph], 0)
        end

        # Get the overriding kerning value, or nil when this subtable does
        # not list the pair.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Integer, nil]
        def override_value_for(left_glyph, right_glyph)
          pairs[[left_glyph, right_glyph]]
        end

        # Recode this subtable using the specified mapping.
        #
        # @param mapping [Hash{Integer => Integer}] keys are old glyph IDs,
        #   values are new glyph IDs
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

          [
            0,
            (num_pairs * 6) + 14,
            attributes[:coverage],
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
