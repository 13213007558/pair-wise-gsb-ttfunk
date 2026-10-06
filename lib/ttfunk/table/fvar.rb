# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Font Variations (`fvar`) table. Defines the variation axes of a
    # variable font together with its named instances.
    #
    # https://learn.microsoft.com/en-us/typography/opentype/spec/fvar
    class Fvar < Table
      # @return [Integer] table version (packed as 16.16 fixed point).
      attr_reader :version

      # @return [Array<Axis>] variation axes, in font order.
      attr_reader :axes

      # @return [Array<NamedInstance>] named instances.
      attr_reader :instances

      TAG = 'fvar'

      # A single variation axis.
      Axis = Struct.new(
        :tag, :min_value, :default_value, :max_value, :flags, :name_id
      ) do
        # @return [Float, Integer] design-space value of the default instance.
        def normalize(value)
          value = [[value, max_value].min, min_value].max

          if value == default_value || min_value == max_value
            0.0
          elsif value < default_value
            (value.to_f - default_value) / (default_value - min_value)
          else
            (value.to_f - default_value) / (max_value - default_value)
          end
        end
      end

      # Helpers for F2DOT14 (signed 2.14) normalized coordinates.
      module F2DOT14
        SCALE = 16_384

        class << self
          # Quantize a normalized coordinate to the F2DOT14 grid. The
          # OpenType instancing pipeline rounds normalized coordinates to
          # this grid before evaluating tuple scalars.
          def round(value)
            scaled = value * SCALE
            ((scaled + 0.5).floor) / SCALE.to_f
          end
        end
      end

      # A named instance: a named location in the variation space.
      NamedInstance = Struct.new(:name_id, :flags, :coordinates, :postscript_name_id)

      private

      def tag
        TAG
      end

      def parse!
        io = StringIO.new(raw)

        @version, offset_to_data, _count_size_pairs,
          axis_count, axis_size,
          instance_count, instance_size = io.read(16).unpack('Nn6')

        @axes = []
        io.pos = offset_to_data
        axis_count.times do
          axis_tag, min_value, default_value, max_value, flags, name_id =
            io.read(axis_size).unpack('A4N*')

          @axes << Axis.new(
            axis_tag,
            fixed(min_value), fixed(default_value), fixed(max_value),
            flags, name_id
          )
        end

        @instances = []
        instance_count.times do
          record = io.read(instance_size)
          name_id, flags = record.unpack('n2')

          coordinates = {}
          axis_count.times do |axis_index|
            coordinates[@axes[axis_index].tag] =
              fixed(record[4 + axis_index * 4, 4].unpack1('N'))
          end

          postscript_name_id = 0xFFFF
          if instance_size > 4 + (axis_count * 4)
            postscript_name_id = record[-2, 2].unpack1('n')
          end

          @instances << NamedInstance.new(
            name_id, flags, coordinates, postscript_name_id
          )
        end
      end

      def fixed(value)
        value / 65_536.0
      end
    end
  end
end
