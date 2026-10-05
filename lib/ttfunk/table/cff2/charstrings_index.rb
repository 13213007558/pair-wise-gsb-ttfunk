# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 Charstrings INDEX.
      class CharstringsIndex < Index
        # Top dict.
        # @return [TTFunk::Table::Cff2::TopDict]
        attr_reader :top_dict

        # Normalized variation coordinates.
        # @return [Hash{Symbol => Numeric}]
        attr_reader :coordinates

        def initialize(top_dict, file, offset, coordinates, length = nil)
          @coordinates = coordinates
          super(file, offset, length)
          @top_dict = top_dict
        end

        # Get a glyph path at the requested normalized coordinates.
        #
        # @param coordinates [Hash{Symbol,Integer => Numeric}]
        # @return [TTFunk::Table::Cff::Path]
        def path_for(index, coordinates = self.coordinates)
          raw = items[index]
          Charstring.new(index, top_dict, font_dict_for(index), raw, coordinates).path
        end

        private

        def decode_item(index, _offset, _length)
          Charstring.new(index, top_dict, font_dict_for(index), super, coordinates)
        end

        def font_dict_for(index)
          return unless top_dict.font_index

          fd_index =
            if top_dict.font_dict_selector
              top_dict.font_dict_selector[index]
            else
              0
            end

          top_dict.font_index[fd_index]
        end
      end
    end
  end
end
