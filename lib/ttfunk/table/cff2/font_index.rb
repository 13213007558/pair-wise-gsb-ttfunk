# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class FontIndex < Cff::Index
        attr_reader :top_dict

        def initialize(top_dict, file, offset, length = nil)
          super(file, offset, length)
          @top_dict = top_dict
        end

        private

        def decode_item(_index, offset, length)
          FontDict.new(top_dict, file, offset, length)
        end
      end
    end
  end
end
