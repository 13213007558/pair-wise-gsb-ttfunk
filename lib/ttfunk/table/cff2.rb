# frozen_string_literal: true

require_relative 'cff'

module TTFunk
  class Table
    # Compact Font Format 2 (`CFF2`) table.
    class Cff2 < TTFunk::Table
      autoload :Charstring, 'ttfunk/table/cff2/charstring'
      autoload :CharstringsIndex, 'ttfunk/table/cff2/charstrings_index'
      autoload :FontDict, 'ttfunk/table/cff2/font_dict'
      autoload :FontIndex, 'ttfunk/table/cff2/font_index'
      autoload :Header, 'ttfunk/table/cff2/header'
      autoload :Index, 'ttfunk/table/cff2/index'
      autoload :PrivateDict, 'ttfunk/table/cff2/private_dict'
      autoload :SubrIndex, 'ttfunk/table/cff2/subr_index'
      autoload :TopDict, 'ttfunk/table/cff2/top_dict'
      autoload :VariationStore, 'ttfunk/table/cff2/variation_store'

      TAG = 'CFF2'

      # CFF2 header.
      # @return [TTFunk::Table::Cff2::Header]
      attr_reader :header

      # Top dict.
      # @return [TTFunk::Table::Cff2::TopDict]
      attr_reader :top_dict

      # Empty CFF2 global subroutine INDEX.
      # @return [TTFunk::Table::Cff2::Index]
      attr_reader :global_subr_index

      # Table tag.
      # @return [String]
      def tag
        TAG
      end

      # Get a glyph path at user-space axis coordinates.
      #
      # @param glyph_id [Integer]
      # @param coordinates [Hash{Symbol,String => Numeric}, Array<Numeric>]
      # @return [TTFunk::Table::Cff::Path]
      def path(glyph_id, coordinates = {})
        top_dict.path(glyph_id, coordinates: coordinates)
      end

      # Axes in variation-space order.
      # @return [Array<TTFunk::Table::Fvar::Axis>]
      def region_axes
        file.font_variations&.axes || []
      end

      # Normalize user-space coordinates. Hash values may already be normalized
      # for fonts without an `fvar` table.
      #
      # @param coordinates [Hash{Symbol,String => Numeric}, Array<Numeric>]
      # @return [Hash{Symbol => Float}]
      def normalize(coordinates)
        return coordinates.transform_keys(&:to_sym) unless file.font_variations&.exists?

        mappings = file.axis_variations&.exists? ? file.axis_variations.mappings : {}
        file.font_variations.normalize(coordinates, mappings)
      end

      private

      def parse!
        @header = read_header
        @top_dict = TopDict.new(self, file, offset + @header.header_size, @header.top_dict_length)
        global_subr_offset = offset + @header.header_size + @header.top_dict_length
        @global_subr_index = Index.new(file, global_subr_offset)
      end

      def read_header
        header = Header.allocate
        header.instance_variable_set(:@file, file)
        header.instance_variable_set(:@table_offset, offset)
        header.instance_variable_set(:@length, nil)

        io = file.contents
        saved_position = io.pos
        io.seek(offset)
        major, minor, header_size, top_dict_length = io.read(4).unpack('CCn1')
        io.seek(saved_position)

        header.instance_variable_set(:@major, major)
        header.instance_variable_set(:@minor, minor)
        header.instance_variable_set(:@header_size, header_size)
        header.instance_variable_set(:@top_dict_length, top_dict_length)
        header
      end
    end
  end
end
