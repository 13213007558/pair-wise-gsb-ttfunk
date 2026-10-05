# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 Font dict.
      class FontDict < TTFunk::Table::Cff::FontDict
        OPERATORS = { private: 18 }.freeze

        OPERATOR_CODES = OPERATORS.invert

        # CFF2 Private dict.
        # @return [TTFunk::Table::Cff2::PrivateDict, nil]
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
