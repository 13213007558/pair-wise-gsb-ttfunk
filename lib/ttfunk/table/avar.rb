# frozen_string_literal: true

module TTFunk
  class Table
    # Axis Variations (`avar`) table.
    class Avar < TTFunk::Table
      # Normalized coordinate mappings keyed by axis index.
      # @return [Hash{Integer => Hash{Float => Float}}]
      attr_reader :mappings

      private

      def parse!
        io.seek(offset + 6)
        axis_count = read(2, 'n').first

        @mappings = {}
        axis_count.times do |axis_index|
          pair_count = read(2, 'n').first
          @mappings[axis_index] =
            Array.new(pair_count) { read(4, 's>2') }
              .to_h { |source, target| [source / 16_384.0, target / 16_384.0] }
        end
      ensure
        io.seek(offset) if offset
      end
    end
  end
end
