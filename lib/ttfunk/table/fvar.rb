# frozen_string_literal: true

module TTFunk
  class Table
    # Font Variations (`fvar`) table
    class Fvar < TTFunk::Table
      Axis = Struct.new(:tag, :min_value, :default_value, :max_value) do
        def normalized_position(value)
          return value.to_f if value.between?(-1.0, 1.0)

          if value < default_value
            return 0.0 if min_value == default_value

            -(default_value - value).to_f / (default_value - min_value)
          else
            return 0.0 if max_value == default_value

            (value - default_value).to_f / (max_value - default_value)
          end
        end
      end

      attr_reader :axes

      private

      def parse!
        header = read(16, 'n*')
        _major, _minor, axes_array_offset, _reserved,
          axis_count, _axis_size, _instance_count, _instance_size = header

        io.seek(offset + axes_array_offset)

        @axes = Array.new(axis_count) do
          tag, min_value, default_value, max_value = read(20, 'a4NNN')
          Axis.new(
            tag,
            fixed_to_float(min_value),
            fixed_to_float(default_value),
            fixed_to_float(max_value)
          )
        end
      end

      def fixed_to_float(value)
        value / 65_536.0
      end
    end
  end
end
