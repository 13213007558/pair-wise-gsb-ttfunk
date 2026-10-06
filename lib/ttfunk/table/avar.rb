# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Axis Variations (`avar`) table.
    class Avar < Table
      # Segment maps for each axis, in `fvar` axis order.
      # @return [Array<Hash{Float => Float}>]
      attr_reader :axis_segments

      # Map a normalized coordinate through this table's piecewise-linear maps.
      #
      # @param coordinate [Hash{String => Float}]
      # @return [Hash{String => Float}]
      def apply(coordinate)
        coordinate.each_with_object({}) do |(tag, value), result|
          index = file.font_variations.axes.index { |axis| axis.tag == tag }
          result[tag] = index ? map_value(value, axis_segments[index]) : value
        end
      end

      private

      def parse!
        io.seek(offset)
        major_version, _minor_version = read(4, 'n*')
        io.read(2) if major_version >= 1
        axis_count = read(2, 'n').first

        @axis_segments = Array.new(axis_count) do
          count = read(2, 'n').first
          {}.tap do |segments|
            count.times do
              from = read_f2dot14
              to = read_f2dot14
              segments[from] = to
            end
          end
        end
      end

      def read_f2dot14
        BinUtils.twos_comp_to_int(read(2, 'n').first, bit_width: 16) / 16_384.0
      end

      def map_value(value, segments)
        return value.to_f unless segments&.any?

        from = segments.keys.sort
        to = from.map { |from_value| segments[from_value] }
        return to.first.to_f if value <= from.first
        return to.last.to_f if value >= from.last

        index = (0...(from.length - 1)).find { |i| value.between?(from[i], from[i + 1]) }
        left = from[index]
        right = from[index + 1]

        return to[index].to_f if left == right

        to[index] + ((value - left) * (to[index + 1] - to[index]) / (right - left))
      end
    end
  end
end
