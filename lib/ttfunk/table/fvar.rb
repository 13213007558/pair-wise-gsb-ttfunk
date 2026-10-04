# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Font Variations (`fvar`) table. Declares the variation axes of a
    # variable font.
    class Fvar < Table
      TAG = 'fvar'

      # A single variation axis.
      #
      # @!attribute tag
      #   @return [String] four-byte axis tag, e.g. "wght"
      # @!attribute min_value
      #   @return [Numeric] smallest valid coordinate
      # @!attribute default_value
      #   @return [Numeric] coordinate used when none is supplied
      # @!attribute max_value
      #   @return [Numeric] largest valid coordinate
      Axis = Struct.new(:tag, :min_value, :default_value, :max_value)

      # Major/minor table version as a packed unsigned integer.
      # @return [Integer]
      attr_reader :version

      # Variation axes declared by the font.
      # @return [Array<Axis>]
      attr_reader :axes

      # Look up an axis by its tag.
      #
      # @param tag [String, Symbol]
      # @return [Axis, nil]
      def axis(tag)
        @axes_by_tag[tag.to_s]
      end

      # Normalize the supplied user-space coordinates.
      #
      # Coordinates outside the `fvar` range are clamped to the nearest end of
      # the range. Axes missing from `coordinates` fall back to their default
      # value. Unknown tags are ignored.
      #
      # The returned values are normalized to the [-1, 1] range and are ready
      # to be passed through `avar`.
      #
      # @param coordinates [Hash{String, Symbol => Numeric}]
      # @return [Hash{String => Float}]
      def normalized_coordinates(coordinates)
        requested = coordinates.transform_keys(&:to_s)

        axes.each_with_object({}) do |axis, result|
          value =
            if requested.key?(axis.tag)
              requested[axis.tag].to_f
            else
              axis.default_value.to_f
            end

          value = clamp(value, axis.min_value.to_f, axis.max_value.to_f)
          result[axis.tag] = normalize(value, axis)
        end
      end

      private

      def clamp(value, min_value, max_value)
        return min_value if value < min_value
        return max_value if value > max_value

        value
      end

      def normalize(value, axis)
        default_value = axis.default_value.to_f

        if value < default_value
          (value - default_value) / (default_value - axis.min_value.to_f)
        elsif value > default_value
          (value - default_value) / (axis.max_value.to_f - default_value)
        else
          0.0
        end
      end

      def parse!
        raw = file.contents.string.byteslice(offset, length)

        version = raw.byteslice(0, 4).unpack1('N')
        major_version = version >> 16
        minor_version = version & 0xFFFF
        axes_array_offset = raw.byteslice(4, 2).unpack1('n')
        axis_count = raw.byteslice(8, 2).unpack1('n')
        axis_size = raw.byteslice(10, 2).unpack1('n')
        @version = (major_version << 16) | minor_version

        @axes =
          Array.new(axis_count) do |index|
            record = raw.byteslice(axes_array_offset + (axis_size * index), axis_size)
            tag = record.byteslice(0, 4).unpack('A4').first
            min_value, default_value, max_value = record.byteslice(4, 12).unpack('N3')
            _flags, _name_id = record.byteslice(16, 4).unpack('n2')

            min_value = signed_fixed(min_value)
            default_value = signed_fixed(default_value)
            max_value = signed_fixed(max_value)

            Axis.new(tag, min_value, default_value, max_value)
          end

        @axes_by_tag = axes.to_h { |axis| [axis.tag, axis] }
      end

      def signed_fixed(value)
        BinUtils.twos_comp_to_int(value, bit_width: 32) / 65536.0
      end
    end
  end
end
