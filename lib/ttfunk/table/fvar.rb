# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Font Variations (`fvar`) table.
    class Fvar < Table
      Axis = Struct.new(:tag, :min_value, :default_value, :max_value,
                        :flags, :name_id, keyword_init: true)

      # Variation axes in font order.
      # @return [Array<Axis>]
      attr_reader :axes

      private

      def parse!
        io.seek(offset)
        io.read(4) # major/minor version
        axes_offset = read(2, 'n').first
        io.read(2) # reserved
        axis_count, axis_size, = read(8, 'n*')

        @axes = Array.new(axis_count) do |index|
          io.seek(offset + axes_offset + (index * axis_size))
          tag = io.read(4)
          min_value, default_value, max_value = read_fixed(3)
          flags, name_id = read(4, 'n*')

          Axis.new(
            tag: tag,
            min_value: min_value,
            default_value: default_value,
            max_value: max_value,
            flags: flags,
            name_id: name_id,
          )
        end
      end

      def read_fixed(count)
        read(count * 4, 'N*').map do |value|
          BinUtils.twos_comp_to_int(value, bit_width: 32) / 65_536.0
        end
      end
    end
  end
end
