# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class VariationRegionList < TTFunk::SubTable
        AxisRegion = Struct.new(:start_coordinate, :peak_coordinate, :end_coordinate)

        attr_reader :axis_count
        attr_reader :regions

        def scalar(coordinates)
          regions.map { |region|
            region.each_with_index.inject(1.0) { |scalar, (axis_region, axis_index)|
              scalar * axis_scalar(axis_region, coordinate_for(coordinates, axis_index))
            }
          }
        end

        private

        def parse!
          @axis_count = read(2, 'n').first
          region_count = read(2, 'n').first

          @regions = Array.new(region_count) do
            Array.new(axis_count) do
            AxisRegion.new(*Array.new(3) { read_fixed_2_14 })
            end
          end
        end

        def coordinate_for(coordinates, axis_index)
          return coordinates[axis_index].to_f if coordinates.is_a?(Array)

          tag = file.fvar.axes[axis_index]&.tag
          return coordinates.fetch(axis_index, 0.0).to_f unless tag

          coordinates.fetch(tag, 0.0).to_f
        end

        def axis_scalar(axis_region, coordinate)
          start_coordinate = axis_region.start_coordinate
          peak_coordinate = axis_region.peak_coordinate
          end_coordinate = axis_region.end_coordinate

          return 0.0 if peak_coordinate.zero?
          return 0.0 unless coordinate.between?(*[start_coordinate, end_coordinate].minmax)

          if coordinate < peak_coordinate
            return 0.0 if start_coordinate == peak_coordinate

            (coordinate - start_coordinate).to_f / (peak_coordinate - start_coordinate)
          else
            return 1.0 if coordinate == peak_coordinate
            return 0.0 if end_coordinate == peak_coordinate

            (end_coordinate - coordinate).to_f / (end_coordinate - peak_coordinate)
          end
        end

        def read_fixed_2_14
          value = read(2, 'n').first
          value -= 0x10000 if value >= 0x8000
          value / 16_384.0
        end
      end
    end
  end
end
