# frozen_string_literal: true

require 'stringio'

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 Item Variation Store (format 1).
      class VariationStore < TTFunk::SubTable
        # Indicates an unsupported variation store format.
        class UnsupportedFormatError < StandardError; end

        # Axes in variation-space order.
        attr_reader :region_axes

        # @param file [TTFunk::File]
        # @param offset [Integer]
        # @param region_axes [Array<Array<Float>>]
        # @param length [Integer]
        def initialize(file, offset, region_axes, length)
          @region_axes = region_axes
          @store_offset = offset
          super(file, offset, length)
        end

        # Number of regions selected by a VarData index.
        #
        # @param vsindex [Integer]
        # @return [Integer]
        def region_count(vsindex)
          var_data(vsindex).region_indices.length
        end

        # Calculate deltas for a blend operator's region deltas.
        #
        # @param vsindex [Integer]
        # @param deltas [Array<Numeric>]
        # @param coordinates [Hash{Symbol,Integer => Numeric}]
        # @return [Numeric]
        def delta(vsindex, deltas, coordinates)
          var_data = var_data(vsindex)

          unless deltas.length == var_data.region_indices.length
            raise ArgumentError,
              "expected #{var_data.region_indices.length} region deltas, got #{deltas.length}"
          end

          var_data.region_indices.each_with_index.sum do |region_index, index|
            deltas[index] * region_scalar(region_index, coordinates)
          end
        end

        private

        VarData = Struct.new(:region_indices, keyword_init: true)

        def var_data(vsindex)
          @var_data_values.fetch(vsindex) do
            raise KeyError, "variation store index #{vsindex} is not present"
          end
        end

        def region_scalar(region_index, coordinates)
          region = @regions.fetch(region_index) do
            raise KeyError, "variation region index #{region_index} is not present"
          end

          axis_values(coordinates).each_with_index.reduce(1.0) do |scalar, (coordinate, axis_index)|
            scalar * axis_scalar(coordinate, region[axis_index])
          end
        end

        def axis_values(coordinates)
          region_axes.each_with_index.map do |axis, index|
            value = coordinates[axis.tag] || coordinates.fetch(index, 0)
            value
          end
        end

        def axis_scalar(coordinate, region_axis)
          start_coord, peak_coord, end_coord = region_axis

          return 0.0 if peak_coord.zero?

          return 0.0 unless coordinate.between?([start_coord, end_coord].min, [start_coord, end_coord].max)

          if peak_coord.negative?
            coordinate.between?(start_coord, peak_coord) ?
              ((coordinate - start_coord).to_f / (peak_coord - start_coord)) :
              ((end_coord - coordinate).to_f / (end_coord - peak_coord))
          else
            coordinate <= peak_coord ?
              ((coordinate - start_coord).to_f / (peak_coord - start_coord)) :
              ((end_coord - coordinate).to_f / (end_coord - peak_coord))
          end
        end

        def parse!
          store_io = StringIO.new(store_bytes)
          format = store_io.read(2).unpack1('n')
          raise UnsupportedFormatError, "unsupported variation store format #{format}" unless format == 1

          region_list_offset = store_io.read(4).unpack1('N')
          var_data_count = store_io.read(2).unpack1('n')
          var_data_offsets = store_io.read(var_data_count * 4).unpack('N*')
          parse_regions(store_io, region_list_offset, var_data_offsets)
        end

        def parse_regions(store_io, region_list_offset, var_data_offsets)
          store_io.seek(region_list_offset)
          axis_count, region_count = store_io.read(4).unpack('n2')
          @regions = Array.new(region_count) do
            Array.new(axis_count) do
              store_io.read(6).unpack('s>3').map { |value| value / 16_384.0 }
            end
          end

          @var_data_values =
            var_data_offsets.map do |offset|
              store_io.seek(offset)
              _item_count, _num_shorts, region_count = store_io.read(6).unpack('n3')
              region_indices = store_io.read(region_count * 2).unpack('n*')
              VarData.new(region_indices: region_indices)
            end
        end

        def store_bytes
          parse_from(@store_offset) do
            io.seek(@store_offset)
            io.read(length)
          end
        end
      end
    end
  end
end
