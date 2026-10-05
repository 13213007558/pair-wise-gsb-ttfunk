# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 Private dict.
      class PrivateDict < TTFunk::Table::Cff::PrivateDict
        OPERATORS = {
          vsindex: 22,
          subrs: 19,
        }.freeze

        OPERATOR_CODES = OPERATORS.invert

        # Local subroutine INDEX.
        # @return [TTFunk::Table::Cff2::SubrIndex, nil]
        def subr_index
          @subr_index ||=
            if (subr_offset = self[OPERATORS[:subrs]])
              SubrIndex.new(file, table_offset + subr_offset.first)
            end
        end

        # Default VariationStore index.
        # @return [Integer]
        def vsindex
          self[OPERATORS[:vsindex]]&.first || 0
        end
      end
    end
  end
end
