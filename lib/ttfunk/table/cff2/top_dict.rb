# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 top dict.
      class TopDict < TTFunk::Table::Cff::Dict
        POINTER_OPERATORS = {
          font_index: 1236,
          font_dict_selector: 1237,
          charstrings_index: 17,
          variation_store: 24,
        }.freeze

        OPERATORS = POINTER_OPERATORS.merge(
          max_stack: 25,
          font_matrix: 1207,
        ).freeze

        OPERATOR_CODES = OPERATORS.invert

        # CFF2 table.
        # @return [TTFunk::Table::Cff2]
        attr_reader :cff2

        # @param cff2 [TTFunk::Table::Cff2]
        # @param file [TTFunk::File]
        # @param offset [Integer]
        # @param length [Integer]
        def initialize(cff2, file, offset, length = nil)
          @cff2 = cff2
          super(file, offset, length)
        end

        # Charstrings INDEX.
        # @return [TTFunk::Table::Cff2::CharstringsIndex]
        def charstrings_index(coordinates = normalized_coordinates)
          @charstrings_index ||= {}
          @charstrings_index[coordinates] ||=
            if (charstrings_offset = self[OPERATORS[:charstrings_index]])
              CharstringsIndex.new(
                self,
                file,
                cff_offset + charstrings_offset.first,
                coordinates,
              )
            end
        end

        # Font dict INDEX.
        # @return [TTFunk::Table::Cff2::FontIndex, nil]
        def font_index
          @font_index ||=
            if (font_index_offset = self[OPERATORS[:font_index]])
              FontIndex.new(self, file, cff_offset + font_index_offset.first)
            end
        end

        # FD selector.
        # @return [TTFunk::Table::Cff::FdSelector, nil]
        def font_dict_selector
          @font_dict_selector ||=
            if (fd_select_offset = self[OPERATORS[:font_dict_selector]])
              TTFunk::Table::Cff::FdSelector.new(self, file, cff_offset + fd_select_offset.first)
            end
        end

        # Item Variation Store.
        # @return [TTFunk::Table::Cff2::VariationStore, nil]
        def variation_store
          @variation_store ||=
            if (variation_store_offset = self[OPERATORS[:variation_store]])
              store_offset = cff_offset + variation_store_offset.first
              payload_length = read_uint16(store_offset)
              VariationStore.new(
                file,
                store_offset + 2,
                cff2.region_axes,
                payload_length,
              )
            end
        end

        # CFF2 table.
        # @return [TTFunk::Table::Cff2]
        alias cff cff2

        # CFF2 has no private dict on the top dict.
        # @return [nil]
        def private_dict
          nil
        end

        # Offset of CFF2 table in the file.
        # @return [Integer]
        def cff_offset
          cff2.offset
        end

        # Get a glyph path at user-space axis coordinates.
        #
        # @param glyph_id [Integer]
        # @param coordinates [Hash{Symbol,String => Numeric}, Array<Numeric>]
        # @return [TTFunk::Table::Cff::Path]
        def path(glyph_id, coordinates: {})
          charstrings_index(cff2.normalize(coordinates))[glyph_id].path
        end

        private

        def normalized_coordinates
          cff2.normalize({})
        end

        def read_uint16(offset)
          saved_position = file.contents.pos
          file.contents.seek(offset)
          value = file.contents.read(2).unpack1('n')
          file.contents.seek(saved_position)
          value
        end

      end
    end
  end
end
