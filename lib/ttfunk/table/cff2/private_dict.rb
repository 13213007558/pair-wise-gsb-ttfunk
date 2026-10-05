# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class PrivateDict < Cff::Dict
        OPERATORS = {
          vsindex: 15,
          subrs: 19,
        }.freeze

        def subr_index
          @subr_index ||=
            if (subr_offset = self[OPERATORS[:subrs]])
              Cff::SubrIndex.new(file, table_offset + subr_offset.first)
            end
        end

        def vsindex
          values = self[OPERATORS[:vsindex]]
          values&.first || 0
        end

        def default_width_x
          0
        end

        def nominal_width_x
          0
        end
      end
    end
  end
end
