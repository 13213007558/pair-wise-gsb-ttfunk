# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class VariationStore < TTFunk::SubTable
        attr_reader :format

        def deltas(variation_data_index, coordinates, item_index = 0)
          parse!
          variation_data = @variation_data[variation_data_index]

          unless variation_data
            raise IndexError, "variation data #{variation_data_index} does not exist"
          end

          scalars = @region_region_list.scalar(coordinates)
          region_indices = variation_data.region_indices

          region_indices.map { |region_index|
            scalars[region_index].to_f
          }
        end

        private

        def parse!
          return if @region_region_list

          @format = read(2, 'n').first
          raise Error, "unsupported variation store format #{@format}" unless @format == 1

          region_list_offset = read(4, 'N').first
          variation_data_count = read(2, 'n').first
          variation_data_offsets = Array.new(variation_data_count) { read(4, 'N').first }

          @region_region_list =
            VariationRegionList.new(file, table_offset + region_list_offset)

          @variation_data = {}
          variation_data_offsets.each_with_index do |data_offset, data_index|
            @variation_data[data_index] =
              VariationData.new(file, table_offset + data_offset)
          end
        end
      end
    end
  end
end
