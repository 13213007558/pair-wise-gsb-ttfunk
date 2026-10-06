# frozen_string_literal: true

module TTFunk
  class Table
    class Gsub < Table
      # GSUB Class Definition table. Assigns glyphs to classes.
      class ClassDef
        # Glyph classes indexed by glyph ID. Glyphs not present in this hash
        # implicitly belong to class 0.
        #
        # @return [Hash{Integer => Integer}]
        attr_reader :classes

        # Parse a ClassDef table.
        #
        # @param data [String] GSUB table content.
        # @param offset [Integer] offset of the ClassDef table in the data.
        # @return [TTFunk::Table::Gsub::ClassDef]
        def self.parse(data, offset)
          format = BinReader.u16(data, offset)
          classes = {}

          case format
          when 1
            first = BinReader.u16(data, offset + 2)
            count = BinReader.u16(data, offset + 4)
            values = BinReader.u16s(data, offset + 6, count)
            values.each_with_index do |value, i|
              classes[first + i] = value
            end
          when 2
            count = BinReader.u16(data, offset + 2)
            count.times do |i|
              first, last, value = BinReader.u16s(data, offset + 4 + (i * 6), 3)
              (first..last).each { |glyph_id| classes[glyph_id] = value }
            end
          else
            raise TTFunk::Error, "unsupported class def format #{format}"
          end

          new(classes)
        end

        # @param classes [Hash{Integer => Integer}]
        def initialize(classes)
          @classes = classes.freeze
        end

        # Get the class the glyph belongs to.
        #
        # @param glyph_id [Integer]
        # @return [Integer]
        def class_of(glyph_id)
          @classes.fetch(glyph_id, 0)
        end

        # Build a new class definition with glyph IDs translated through the
        # map. Glyphs missing from the map are dropped.
        #
        # @param map [Hash{Integer => Integer}]
        # @return [TTFunk::Table::Gsub::ClassDef]
        def remap(map)
          kept = {}
          @classes.each do |glyph_id, value|
            new_id = map[glyph_id]
            kept[new_id] = value if new_id
          end
          self.class.new(kept)
        end

        # Serialize to binary (always in format 2).
        #
        # @return [String]
        def encode
          ranges = []
          @classes.keys.sort.each do |glyph_id|
            value = @classes[glyph_id]
            if ranges.last && ranges.last[2] == value && ranges.last[1] == glyph_id - 1
              ranges.last[1] = glyph_id
            else
              ranges << [glyph_id, glyph_id, value]
            end
          end

          [2, ranges.length, *ranges.flatten].pack('nnn*')
        end
      end
    end
  end
end
