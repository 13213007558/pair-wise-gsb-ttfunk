# frozen_string_literal: true

require_relative 'record'

module TTFunk
  class Table
    class Math < Table
      # OpenType Device table used to tune a value at particular ppem sizes.
      class Device < Record
        attr_reader :start_size
        attr_reader :end_size
        attr_reader :delta_format
        attr_reader :adjustments

        private

        def parse!
          @start_size, @end_size, @delta_format = read(6, 'n*')
          malformed!('device start size is larger than end size') if start_size > end_size

          count = end_size - start_size + 1
          @adjustments =
            case delta_format
            when 1 then read_packed_deltas(count, 2)
            when 2 then read_packed_deltas(count, 4)
            when 3 then read(count, 'C*').map { |delta| signed(delta, 8) }
            else malformed!("unsupported device delta format #{delta_format}")
            end
        end

        def read_packed_deltas(count, bits)
          values_per_word = 16 / bits
          words = (count.to_f / values_per_word).ceil
          mask = (1 << bits) - 1

          read(words * 2, 'n*').flat_map do |word|
            values_per_word.times.map do |index|
              shift = 16 - (bits * (index + 1))
              signed((word >> shift) & mask, bits)
            end
          end.first(count)
        end

        def signed(value, bits)
          sign_bit = 1 << (bits - 1)
          value >= sign_bit ? value - (1 << bits) : value
        end

        public

        def adjustment_for(ppem)
          return 0 unless ppem.between?(start_size, end_size)

          adjustments.fetch(ppem - start_size)
        end
      end
    end
  end
end
