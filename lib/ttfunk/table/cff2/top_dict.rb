# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class TopDict < Cff::Dict
        OPERATORS = {
          charstrings: 17,
          variation_store: 24,
          private: 18,
          font_index: 1236,
          font_dict_selector: 1237,
        }.freeze

        def charstrings_index
          @charstrings_index ||=
            if (charstrings_offset = self[OPERATORS[:charstrings]])
              CharstringsIndex.new(self, file, cff_offset + charstrings_offset.first)
            end
        end

        def variation_store
          @variation_store ||=
            if (variation_store_offset = self[OPERATORS[:variation_store]])
              VariationStore.new(file, cff_offset + variation_store_offset.first)
            end
        end

        def font_index
          @font_index ||=
            if (font_index_offset = self[OPERATORS[:font_index]])
              FontIndex.new(self, file, cff_offset + font_index_offset.first)
            end
        end

        def font_dict_selector
          @font_dict_selector ||=
            if (fd_select_offset = self[OPERATORS[:font_dict_selector]])
              FdSelector.new(self, file, cff_offset + fd_select_offset.first)
            end
        end

        def private_dict
          @private_dict ||=
            if (info = self[OPERATORS[:private]])
              private_dict_length, private_dict_offset = info
              PrivateDict.new(file, cff_offset + private_dict_offset, private_dict_length)
            end
        end

        def cff
          file.cff2
        end

        def cff_offset
          cff.offset
        end

        private

        def operator_ranges
          [0..27]
        end
      end
    end
  end
end
