# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Axis Variations (`avar`) table. Remaps normalized axis coordinates
    # produced from `fvar` into the normalized space used by variation data.
    class Avar < Table
      TAG = 'avar'

      # Major/minor table version as a packed unsigned integer.
      # @return [Integer]
      attr_reader :version

      # Piecewise-linear maps keyed by axis tag. Each map is an ordered array
      # of [normalized input, normalized output] pairs.
      # @return [Hash{String => Array<Array(Float, Float)>}]
      attr_reader :segment_maps

      # Apply the segment map of an axis to a normalized coordinate.
      #
      # Coordinates before the first or after the last mapping segment are
      # extended with a constant value. The implicit (-1, -1) and (1, 1)
      # endpoints defined by the OpenType specification are added when the
      # table does not list them explicitly.
      #
      # @param tag [String, Symbol]
      # @param value [Float] coordinate in [-1, 1]
      # @return [Float]
      def map(tag, value)
        segments = @segment_maps[tag.to_s]
        return value unless segments

        from = segments.map(&:first)
        return segments.first.last if value <= from.first
        return segments.last.last if value >= from.last

        index = (0...(segments.length - 1)).find do |i|
          value >= from[i] && value <= from[i + 1]
        end

        x1, y1 = segments[index]
        x2, y2 = segments[index + 1]

        return y1 if x1 == x2

        y1 + ((value - x1) * (y2 - y1) / (x2 - x1))
      end

      private

      def parse!
        io.seek(offset)

        major_version, minor_version, _reserved, axis_count =
          io.read(8).unpack('n4')
        @version = (major_version << 16) | minor_version
        @segment_maps = {}

        ordered_tags = file.font_variations.axes.map(&:tag) if file.font_variations.exists?

        axis_count.times do
          axis_tag, pairs =
            if @version >= 0x00020000
              tag = io.read(4).unpack1('A4')
              map_offset = io.read(4).unpack1('N')
              [tag, read_version_two_map(map_offset)]
            else
              segment_count = io.read(2).unpack1('n')
              tag = ordered_tags&.at(@segment_maps.size)
              [tag, Array.new(segment_count) { read_signed_pair }]
            end

          @segment_maps[axis_tag] = with_implicit_endpoints(pairs) if axis_tag
        end
      end

      def read_version_two_map(map_offset)
        saved = io.pos
        io.seek(offset + map_offset)
        segment_count = io.read(2).unpack1('n')
        pairs = Array.new(segment_count) { read_signed_pair }
        io.seek(saved)
        pairs
      end

      def read_signed_pair
        from = f2dot14(io.read(2).unpack1('n'))
        to = f2dot14(io.read(2).unpack1('n'))
        [from, to]
      end

      def with_implicit_endpoints(pairs)
        pairs = [[-1.0, -1.0]] + pairs unless pairs.first&.first == -1.0
        pairs << [1.0, 1.0] unless pairs.last&.first == 1.0
        pairs.sort_by(&:first)
      end

      def f2dot14(value)
        BinUtils.twos_comp_to_int(value, bit_width: 16) / 16384.0
      end
    end
  end
end
