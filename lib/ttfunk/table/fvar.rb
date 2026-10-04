# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Font Variations (`fvar`) table.
    class Fvar < Table
      Axis = Struct.new(:tag, :minimum, :default, :maximum, :flags, :name_id)

      # @return [Array<Axis>]
      attr_reader :axes

      # Normalize user-space coordinates to the [-1, 1] variation space.
      # Missing axes use their default coordinate.
      #
      # @param coordinates [Hash{String, Symbol => Numeric}]
      # @param avar [TTFunk::Table::Avar, nil]
      # @return [Hash{String => Rational}]
      def normalized_coordinates(coordinates, avar = nil)
        provided = coordinates.transform_keys { |tag| tag.to_s }
        unknown = provided.keys.map(&:to_s) - axes.map(&:tag)

        unless unknown.empty?
          raise ArgumentError, "unknown variation axis: #{unknown.first.inspect}"
        end

        axes.each_with_object({}) do |axis, normalized|
          value = provided.fetch(axis.tag, axis.default)

          unless value.between?(axis.minimum, axis.maximum)
            raise ArgumentError,
              "coordinate #{axis.tag}=#{value} is outside " \
              "[#{axis.minimum}, #{axis.maximum}]"
          end

          coordinate =
            if value == axis.default
              Rational(0)
            elsif value < axis.default
              Rational(value - axis.default) / Rational(axis.default - axis.minimum)
            else
              Rational(value - axis.default) / Rational(axis.maximum - axis.default)
            end

          normalized[axis.tag] = avar ? avar.map(axis.tag, coordinate) : coordinate
        end
      end

      private

      def parse!
        parse_from(offset) do
          io.read(4)
          axes_array_offset = io.read(4).unpack1('N')
          axis_count = io.read(2).unpack1('n')
          axis_size = io.read(2).unpack1('n')
          instance_count = io.read(2).unpack1('n')
          instance_size = io.read(2).unpack1('n')

          @axes = []
          io.pos = offset + axes_array_offset

          axis_count.times do
            tag = io.read(4)
            minimum, default_value, maximum = io.read(12).unpack('N*').map { |v| fixed(v) }
            _flags, name_id = io.read(4).unpack('n2')

            @axes << Axis.new(tag, minimum, default_value, maximum, _flags, name_id)
          end

          # Named instances are metadata and do not affect an arbitrary location.
          io.pos = offset + axes_array_offset + axis_count * axis_size +
            instance_count * instance_size
        end
      end

      def fixed(value)
        value = BinUtils.twos_comp_to_int(value, bit_width: 32)
        Rational(value, 0x10000)
      end
    end
  end
end
