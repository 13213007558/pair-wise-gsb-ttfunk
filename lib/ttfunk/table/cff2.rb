# frozen_string_literal: true

module TTFunk
  class Table
    # Compact Font Format 2 (`CFF2`) table
    class Cff2 < TTFunk::Table
      autoload :Charstring, 'ttfunk/table/cff2/charstring'
      autoload :CharstringsIndex, 'ttfunk/table/cff2/charstrings_index'
      autoload :FdSelector, 'ttfunk/table/cff2/fd_selector'
      autoload :FontDict, 'ttfunk/table/cff2/font_dict'
      autoload :FontIndex, 'ttfunk/table/cff2/font_index'
      autoload :Header, 'ttfunk/table/cff2/header'
      autoload :PrivateDict, 'ttfunk/table/cff2/private_dict'
      autoload :TopDict, 'ttfunk/table/cff2/top_dict'
      autoload :VariationData, 'ttfunk/table/cff2/variation_data'
      autoload :VariationRegionList, 'ttfunk/table/cff2/variation_region_list'
      autoload :VariationStore, 'ttfunk/table/cff2/variation_store'

      TAG = 'CFF2'

      attr_reader :header
      attr_reader :top_dict
      attr_reader :global_subr_index

      def tag
        TAG
      end

      private

      def parse!
        @header = Header.new(file, offset)
        top_dict_offset = offset + header.length
        @top_dict = TopDict.new(file, top_dict_offset, header.top_dict_length)

        global_subr_offset = top_dict_offset + header.top_dict_length
        @global_subr_index = Cff::SubrIndex.new(file, global_subr_offset)
      end
    end
  end
end
