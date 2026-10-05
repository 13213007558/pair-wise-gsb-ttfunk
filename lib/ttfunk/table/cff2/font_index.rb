# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 Font dict INDEX.
      class FontIndex < Index
        # Top dict.
        # @return [TTFunk::Table::Cff2::TopDict]
        attr_reader :top_dict

        def initialize(top_dict, file, offset, length = nil)
          @top_dict = top_dict
          super(file, offset, length)
        end

        private

        def decode_item(_index, offset, length)
          FontDict.new(top_dict, file, offset, length)
        end
      end
    end
  end
end
