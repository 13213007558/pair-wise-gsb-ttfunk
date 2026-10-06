# frozen_string_literal: true

module TTFunk
  module Variation
    # IUP ("inference of unattached points") interpolation used to expand
    # sparse gvar delta lists into one delta per point.
    #
    # @see https://learn.microsoft.com/en-us/typography/opentype/spec/gvar
    module Iup
      module_function

      # Expand +deltas+ (whose omitted entries are +nil+) for an outline.
      #
      # @param deltas [Array<Array(Integer, Integer)>, nil] one +[dx, dy]+
      #   entry per point, including the four phantom points; +nil+ marks the
      #   points omitted from the tuple.
      # @param coordinates [Array<Array(Integer, Integer)>] default
      #   coordinates of every point including the phantom points.
      # @param contour_ends [Array<Integer>] index of the last point of each
      #   contour, or of each component for composite glyphs.
      # @return [Array<Array(Float, Float)>] fully expanded deltas.
      def expand(deltas, coordinates, contour_ends)
        return deltas unless deltas.include?(nil)

        result = Array.new(deltas.length) { [0.0, 0.0] }
        start = 0
        ends = contour_ends + [
          deltas.length - 4, deltas.length - 3,
          deltas.length - 2, deltas.length - 1
        ]

        ends.each do |last_index|
          finish = last_index + 1
          contour_deltas = deltas[start...finish]
          contour_coordinates = coordinates[start...finish]
          interpolate_contour(contour_deltas, contour_coordinates)
            .each_with_index do |delta, index|
              result[start + index] = delta
            end
          start = finish
        end

        result
      end

      # Interpolate missing deltas of one closed contour.
      def interpolate_contour(deltas, coordinates)
        return deltas unless deltas.include?(nil)

        count = deltas.length
        explicit = deltas.each_index.select { |index| deltas[index] }
        return Array.new(count) { [0.0, 0.0] } if explicit.empty?

        result = Array.new(count)
        first = explicit.first

        if first > 0
          fill_gap(result, deltas, coordinates, 0...first,
                   explicit.last, first)
        end
        result[first] = to_float(deltas[first])

        explicit.each_cons(2) do |left, right|
          if right - left > 1
            fill_gap(result, deltas, coordinates, (left + 1)...right,
                     left, right)
          end
          result[right] = to_float(deltas[right])
        end

        last = explicit.last
        if last < count - 1
          fill_gap(result, deltas, coordinates,
                   (last + 1)...count, last, explicit.first)
        end

        result
      end

      def fill_gap(result, deltas, coordinates, range, left, right)
        range.each do |index|
          result[index] = interpolate_point(
            coordinates[index],
            coordinates[left], coordinates[right],
            deltas[left], deltas[right]
          )
        end
      end

      def interpolate_point(point, start_point, end_point,
                            start_delta, end_delta)
        [
          interpolate_axis(point[0], start_point[0], end_point[0],
                           start_delta[0], end_delta[0]),
          interpolate_axis(point[1], start_point[1], end_point[1],
                           start_delta[1], end_delta[1]),
        ]
      end

      def interpolate_axis(value, start_coord, end_coord,
                           start_delta, end_delta)
        return start_delta.to_f if start_coord == end_coord &&
                                  start_delta == end_delta
        return 0.0 if start_coord == end_coord

        if start_coord > end_coord
          start_coord, end_coord = end_coord, start_coord
          start_delta, end_delta = end_delta, start_delta
        end

        return start_delta.to_f if value <= start_coord
        return end_delta.to_f if value >= end_coord

        slope = (end_delta - start_delta).to_f / (end_coord - start_coord)
        start_delta + (value - start_coord) * slope
      end

      def to_float(delta)
        [delta[0].to_f, delta[1].to_f]
      end
    end

    # Per-axis piecewise-linear OpenType tent scalar.
    module Scalar
      module_function

      # Product of the per-axis tent scalars for all axes of a tuple
      # region at the given (mapped) normalized location.
      #
      # @param region [Hash{String => Array(Float, Float, Float)}] axis tag
      #   to [start, peak, finish].
      # @param location [Hash{String => Float}] mapped normalized location.
      # @return [Float]
      def for_region(region, location)
        region.reduce(1.0) do |scalar, (tag, (start, peak, finish))|
          scalar * tent(location.fetch(tag, 0.0), start, peak, finish)
        end
      end

      # Single-axis tent function.
      def tent(value, start, peak, finish)
        return 1.0 if peak.zero?
        return 0.0 unless start <= peak && peak <= finish
        return 0.0 if start.negative? && finish.positive?
        return 0.0 if value < start || finish < value
        return 1.0 if value == peak

        if value < peak
          (value - start).to_f / (peak - start)
        else
          (finish - value).to_f / (finish - peak)
        end
      end
    end
  end
end
