# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Axis Variations (`avar`) table.
    class Avar < Table
      Segment = Struct.new(:from, :to)

      # @return [Hash{String => Array<Segment>}]
      attr_reader :segments

      # Map a normalized coordinate through an axis's piecewise segment map.
      #
      # @param axis_tag [String]
      # @param coordinate [Numeric]
      # @return [Rational]
      def map(axis_tag, coordinate)
        axis_segments = @segments[axis_tag]
        return Rational(coordinate) unless axis_segments

        normalized = Rational(coordinate)

        axis_segments.each_cons(2) do |left, right|
          next unless normalized.between?(left.from, right.from)

          if left.from == right.from
            return Rational(right.to)
          end

          position = (normalized - left.from) / (right.from - left.from)
          return Rational(left.to) + position * Rational(right.to - left.to)
        end

        Rational(normalized)
      end

      private

      def parse!
        _major, _minor, axis_count = read(6, 'n3')
        @segments = {}

        axis_count.times do
          axis_tag, position_map_count = io.read(6).unpack('a4n')
        @segments[axis_tag] = []

        position_map_count.times do
            from, to = io.read(4).unpack('s>2')
            @segments[axis_tag] << Segment.new(Rational(from, 0x10000), Rational(to, 0x10000))
          end
        end
      end
    end
  end
end
