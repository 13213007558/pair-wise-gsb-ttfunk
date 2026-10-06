# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Axis Variations (`avar`) table (version 1). Maps normalized axis
    # coordinates to "mapped" normalized coordinates with a piecewise linear
    # mapping, one segment map per axis.
    #
    # https://learn.microsoft.com/en-us/typography/opentype/spec/avar
    class Avar < Table
      TAG = 'avar'

      VERSION_2 = 0x00020000

      class Version2NotSupportedError < Error
        def initialize
          super('version 2 `avar` tables with a variable-axis variation data store are not supported')
        end
      end

      # @return [Integer] table version as a packed 16.16 fixed point value.
      attr_reader :version

      # Segment maps, keyed by axis tag (in fvar axis order). Each value is
      # a Hash mapping normalized source coordinates to normalized mapped
      # coordinates.
      # @return [Hash{String => Hash{Float => Float}}]
      attr_reader :segments

      # Apply this table's piecewise linear mapping to a hash of normalized
      # axis coordinates.
      #
      # @param normalized [Hash{String => Float}] normalized coordinates.
      # @return [Hash{String => Float}] mapped coordinates.
      def apply(normalized)
        normalized.each_with_index.each_with_object({}) do |(tag_value, index), result|
          tag, value = tag_value
          axis = file.fvar.axes[index]
          segment = @segments[axis.tag]
          result[tag] = segment ? piecewise_linear_map(value, segment) : value
        end
      end

      private

      def tag
        TAG
      end

      def parse!
        data = raw
        @version = data[0, 4].unpack1('N')

        raise Version2NotSupportedError if @version >= VERSION_2

        io = StringIO.new(data)
        io.pos = 6 # version (4 bytes) + reserved (2 bytes)
        axis_count = io.read(2).unpack1('n')

        @segments = {}
        file.fvar.axes.first(axis_count).each do |axis|
          position_map_count = io.read(2).unpack1('n')
          mapping = {}

          position_map_count.times do
            from = f2dot14(io.read(2).unpack1('n'))
            to = f2dot14(io.read(2).unpack1('n'))
            mapping[from] = to
          end

          @segments[axis.tag] = mapping
        end
      end

      def piecewise_linear_map(value, mapping)
        return value if mapping.empty?
        return mapping[value] if mapping.key?(value)

        keys = mapping.keys
        low = keys.min
        high = keys.max

        return value + mapping[low] - low if value < low
        return value + mapping[high] - high if value > high

        left = keys.select { |key| key < value }.max
        right = keys.select { |key| key > value }.min

        mapping[left] +
          (mapping[right] - mapping[left]) *
          (value - left) / (right - left)
      end

      def f2dot14(value)
        value = value - 0x10000 if value >= 0x8000
        value / 16_384.0
      end
    end
  end
end
