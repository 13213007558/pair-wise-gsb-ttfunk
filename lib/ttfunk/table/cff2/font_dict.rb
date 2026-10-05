# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class FontDict < Cff::Dict
        attr_reader :top_dict

        OPERATORS = {
          private: 18,
        }.freeze

        def initialize(top_dict, file, offset, length = nil)
          @top_dict = top_dict
          super(file, offset, length)
        end

        def private_dict
          @private_dict ||=
            if (info = self[OPERATORS[:private]])
              private_dict_length, private_dict_offset = info
              PrivateDict.new(
                file,
                top_dict.cff_offset + private_dict_offset,
                private_dict_length,
              )
            end
        end
      end
    end
  end
end
