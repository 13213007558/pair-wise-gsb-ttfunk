# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class VariationData < TTFunk::SubTable
        attr_reader :item_count
        attr_reader :region_indices

        private

        def parse!
          return if @region_indices

          @item_count = read(2, 'n').first
          _short_delta_count = read(2, 'n').first
          region_index_count = read(2, 'n').first
          @region_indices = Array.new(region_index_count) { read(2, 'n').first }
        end
      end
    end
  end
end
