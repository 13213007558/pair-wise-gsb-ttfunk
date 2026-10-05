# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class CharstringsIndex < Cff::Index
        attr_reader :top_dict

        def initialize(top_dict, *remaining_args)
          super(*remaining_args)
          @top_dict = top_dict
        end

        def for(glyph_id, coordinates = {})
          self[glyph_id].path(coordinates: coordinates)
        end

        private

        def decode_item(index, _offset, _length)
          Charstring.new(index, top_dict, font_dict_for(index), super)
        end

        def font_dict_for(index)
          if top_dict.font_dict_selector
            fd_index = top_dict.font_dict_selector[index]
            top_dict.font_index[fd_index]
          end
        end
      end
    end
  end
end
