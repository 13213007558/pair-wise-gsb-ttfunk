# frozen_string_literal: true

module TTFunk
  class Table
    class Gsub < Table
      # GSUB Coverage table. Describes a set of glyphs.
      class Coverage
        # Glyph IDs in this coverage, sorted in ascending order.
        #
        # @return [Array<Integer>]
        attr_reader :glyphs

        # Parse a Coverage table.
        #
        # @param data [String] GSUB table content.
        # @param offset [Integer] offset of the Coverage table in the data.
        # @return [TTFunk::Table::Gsub::Coverage]
        def self.parse(data, offset)
          format = BinReader.u16(data, offset)

          case format
          when 1
            count = BinReader.u16(data, offset + 2)
            new(BinReader.u16s(data, offset + 4, count))
          when 2
            count = BinReader.u16(data, offset + 2)
            glyphs = []
            count.times do |i|
              first, last, = BinReader.u16s(data, offset + 4 + (i * 6), 3)
              (first..last).each { |glyph_id| glyphs << glyph_id }
            end
            new(glyphs)
          else
            raise TTFunk::Error, "unsupported coverage format #{format}"
          end
        end

        # @param glyphs [Array<Integer>]
        def initialize(glyphs)
          @glyphs = glyphs.uniq.sort.freeze
        end

        # Does this coverage contain the glyph?
        #
        # @param glyph_id [Integer]
        # @return [Boolean]
        def cover?(glyph_id)
          @glyphs.include?(glyph_id)
        end

        # Build a new coverage with glyph IDs translated through the map.
        # Glyphs missing from the map are dropped.
        #
        # @param map [Hash{Integer => Integer}]
        # @return [TTFunk::Table::Gsub::Coverage, nil] nil if no glyphs are
        #   left.
        def remap(map)
          kept = @glyphs.filter_map { |glyph_id| map[glyph_id] }
          kept.empty? ? nil : self.class.new(kept)
        end

        # Serialize to binary (always in format 1).
        #
        # @return [String]
        def encode
          [1, @glyphs.length, *@glyphs].pack('nnn*')
        end
      end
    end
  end
end
