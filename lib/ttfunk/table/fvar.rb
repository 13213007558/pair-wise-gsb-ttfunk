# frozen_string_literal: true

module TTFunk
  class Table
    # Font Variations (`fvar`) table.
    class Fvar < TTFunk::Table
      Axis = Struct.new(:tag, :min_value, :default_value, :max_value, keyword_init: true) do
        # Map a user-space coordinate to the normalized [-1, 1] range.
        #
        # @param value [Numeric]
        # @return [Float]
        def normalized(value)
          if value == default_value
            0.0
          elsif value < default_value
            -(default_value - value).to_f / (default_value - min_value)
          else
            (value - default_value).to_f / (max_value - default_value)
          end
        end
      end

      # Variation axes.
      # @return [Array<Axis>]
      attr_reader :axes

      # @param coordinates [Hash{Symbol,String => Numeric}, Array<Numeric>]
      # @param mappings [Hash{Integer => Hash{Integer => Float}}] avar mappings by axis index
      # @return [Hash{Symbol => Float}]
      def normalize(coordinates, mappings = {})
        axes.each_with_index.each_with_object({}) do |(axis, index), normalized|
          value = coordinate_for(coordinates, axis.tag, index)
          value = axis.normalized(value)
          value = apply_avar(value, mappings[index]) if mappings[index]&.any?
          normalized[axis.tag] = value.clamp(-1.0, 1.0)
        end
      end

      private

      def coordinate_for(coordinates, tag, index)
        case coordinates
        when Hash
          coordinates.fetch(tag) { coordinates.fetch(tag.to_s, 0) }
        else
          coordinates[index] || 0
        end
      end

      def apply_avar(value, mapping)
        return 0.0 if value.zero?

        relevant = mapping.select do |source, _target|
          value.negative? ? source.negative? : !source.negative?
        end.sort.to_h

        from = [value.negative? ? -1.0 : 0.0, *relevant.keys]
        to = [from.first, *relevant.values]

        from << (value.negative? ? 0.0 : 1.0)
        to << (value.negative? ? 0.0 : 1.0)

        pairs = from.each_cons(2).zip(to.each_cons(2))
        source_range, target_range =
          pairs.find { |(source_start, source_end), _| value.between?(source_start, source_end) }

        ratio = (value - source_range[0]).to_f / (source_range[1] - source_range[0])
        target_range[0] + (ratio * (target_range[1] - target_range[0]))
      end

      def parse!
        _major, _minor, axes_offset = read(8, 'nnN')
        axis_count, axes_size, _instance_count, _instance_size = read(8, 'nnnn')

        io.seek(offset + axes_offset)
        @axes =
          Array.new(axis_count) do
            tag, min_value, default_value, max_value, _flags, _name_id =
              io.read(axes_size).unpack('a4NNNnn')

            Axis.new(
              tag: tag.to_sym,
              min_value: fixed_to_float(min_value),
              default_value: fixed_to_float(default_value),
              max_value: fixed_to_float(max_value),
            )
          end
      ensure
        io.seek(offset) if offset
      end

      def fixed_to_float(value)
        signed = value >= 0x8000_0000 ? value - 0x1_0000_0000 : value
        signed / 65_536.0
      end
    end
  end
end
