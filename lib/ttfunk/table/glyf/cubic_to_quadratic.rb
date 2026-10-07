# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # Converts interpreted cubic outlines to integer TrueType outlines.
      class CubicToQuadratic
        Point = Struct.new(:x, :y)
        class Point
          def +(other)
            self.class.new(x + other.x, y + other.y)
          end

          def -(other)
            self.class.new(x - other.x, y - other.y)
          end

          def *(factor)
            self.class.new(x * factor, y * factor)
          end

          def /(factor)
            self.class.new(x / factor, y / factor)
          end
        end
        Segment = Struct.new(
          :type,
          :points,
          :source,
          :t_range,
          keyword_init: true,
        )

        Result = Struct.new(:contours, :max_error, :segment_count, keyword_init: true)

        DEFAULT_MAX_SEGMENTS_PER_CURVE = 1024
        MAX_POINTS = 65_535
        MAX_CONTOURS = 65_535

        attr_reader :path, :max_error, :max_segments, :max_depth

        def self.convert(path, max_error:, max_segments: DEFAULT_MAX_SEGMENTS_PER_CURVE)
          new(path, max_error: max_error, max_segments: max_segments).convert
        end

        def initialize(path, max_error:, max_segments: DEFAULT_MAX_SEGMENTS_PER_CURVE)
          raise ArgumentError, 'max_error must be non-negative' if max_error.negative?

          unless max_segments.positive? && (max_segments & (max_segments - 1)).zero?
            raise ArgumentError, 'max_segments must be a positive power of two'
          end

          @path = path
          @max_error = max_error.to_f
          @max_segments = max_segments
          @max_depth = Math.log2(max_segments).to_i
        end

        def convert
          contours = []
          current = nil
          contour_start = nil
          current_point = nil
          rounded_current_point = nil
          segment_count = 0
          observed_error = 0.0

          path.commands.each do |command|
            type = command.first

            case type
            when :move
              raise ArgumentError, 'cannot start a contour before closing the previous contour' if current

              current = []
              contour_start = float_point(command[1], command[2])
              current_point = contour_start
              rounded_current_point = rounded_point(contour_start)
              observed_error = [
                observed_error,
                ensure_within_tolerance!(contour_start, rounded_current_point),
              ].max
            when :line
              raise ArgumentError, 'line command outside a contour' unless current

              endpoint = float_point(command[1], command[2])
              observed_error = [observed_error, line_error(current_point, endpoint)].max
              append_point(current, rounded_current_point, on_curve: true) if current.empty?
              append_point(current, rounded_point(endpoint), on_curve: true)
              current_point = endpoint
              rounded_current_point = rounded_point(endpoint)
            when :curve
              raise ArgumentError, 'curve command outside a contour' unless current

              controls = command[1..].each_slice(2).map { |x, y| float_point(x, y) }
              cubic = [current_point, *controls]
              append_point(current, rounded_current_point, on_curve: true) if current.empty?

              segments, curve_error =
                convert_curve(cubic, 1, 0.0, 1.0, rounded_current_point)
              segment_count += segments.count
              observed_error = [observed_error, curve_error].max
              current.concat(segments)
              current_point = controls.last
              rounded_current_point = segments.last.points.last
            when :close
              raise ArgumentError, 'close command without an open contour' unless current

              if current.any? && current.last.points.last != rounded_point(contour_start)
                observed_error = [
                  observed_error,
                  line_error(current_point, contour_start),
                ].max
              end

              append_point(current, rounded_point(contour_start), on_curve: true)
              contours << current unless current.count < 2
              current = nil
              current_point = nil
              rounded_current_point = nil
              contour_start = nil
            end
          end

          raise ArgumentError, 'path contains an unclosed contour' if current

          if contours.count > MAX_CONTOURS
            raise ArgumentError, "glyph contains more than #{MAX_CONTOURS} contours"
          end

          if contours.sum(&:count) > MAX_POINTS
            raise ArgumentError, "glyph contains more than #{MAX_POINTS} points"
          end

          Result.new(
            contours: contours,
            max_error: observed_error,
            segment_count: segment_count,
          )
        end

        private

        def convert_curve(
          cubic,
          depth,
          t_start = 0.0,
          t_end = 1.0,
          rounded_start = rounded_point(cubic.first)
        )
          endpoint = rounded_point(cubic.last)
          control = rounded_point(quadratic_control(cubic))
          first_delta = cubic[1] * 3.0 - cubic[0] - control * 2.0
          second_delta = cubic[2] * 3.0 - cubic[3] - control * 2.0
          curve_error = [
            distance(cubic.first, rounded_start),
            distance(cubic.last, endpoint),
            distance(control, quadratic_control(cubic)),
            cubic_approximation_error(first_delta, second_delta),
          ].max

          line_deviation = deviation_as_line(cubic, endpoint, rounded_start)
          chord_deviation =
            [
              distance_to_segment(cubic[1], cubic.first, cubic.last),
              distance_to_segment(cubic[2], cubic.first, cubic.last),
            ].max

          if chord_deviation <= max_error && line_deviation <= max_error
            return [
              Segment.new(
                type: :line,
                points: [endpoint],
                source: cubic,
                t_range: t_start..t_end,
              ),
            ], line_deviation
          end

          if curve_error <= max_error
            return [
              Segment.new(
                type: :curve,
                points: [control, endpoint],
                source: cubic,
                t_range: t_start..t_end,
              ),
            ], curve_error
          end

          if depth > max_depth
            raise ArgumentError,
              "curve requires more than #{max_segments} segments to satisfy tolerance"
          end

          left, right = split_cubic(cubic)
          t_middle = (t_start + t_end) / 2.0
          rounded_middle = rounded_point(left.last)
          left_segments, left_error =
            convert_curve(left, depth + 1, t_start, t_middle, rounded_start)
          right_segments, right_error =
            convert_curve(right, depth + 1, t_middle, t_end, rounded_middle)

          [left_segments + right_segments, [left_error, right_error].max]
        end

        def line_error(start, endpoint)
          rounded_endpoint = rounded_point(endpoint)
          rounded_start = rounded_point(start)
          [
            distance(start, rounded_start),
            distance(rounded_endpoint, endpoint),
            distance_to_segment(start, rounded_start, rounded_endpoint),
            distance_to_segment(endpoint, rounded_start, rounded_endpoint),
          ].max
        end

        def ensure_within_tolerance!(point, rounded_point)
          error = distance(point, rounded_point)
          raise ArgumentError, 'coordinate rounding exceeds the requested tolerance' if error > max_error

          error
        end

        def deviation_as_line(cubic, endpoint, rounded_start)
          [
            distance(cubic.first, rounded_start),
            distance(cubic.last, endpoint),
            distance_to_segment(cubic[1], rounded_start, endpoint),
            distance_to_segment(cubic[2], rounded_start, endpoint),
          ].max
        end

        def quadratic_control(cubic)
          (
            cubic[1] * 3.0 + cubic[2] * 3.0 - cubic[0] - cubic[3]
          ) * 0.25
        end

        def split_cubic(cubic)
          p0, p1, p2, p3 = cubic
          q1 = midpoint(p0, p1)
          q2 = midpoint(p1, p2)
          q3 = midpoint(p2, p3)
          r1 = midpoint(q1, q2)
          r2 = midpoint(q2, q3)
          s = midpoint(r1, r2)

          [[p0, q1, r1, s], [s, r2, q3, p3]]
        end

        def append_point(contour, point, on_curve:)
          return unless on_curve
          return if contour.last&.points&.last == point

          contour << Segment.new(type: :line, points: [point])
        end

        def float_point(x, y)
          Point.new(x.to_f, y.to_f)
        end

        def rounded_point(point)
          Point.new(round_coordinate(point.x), round_coordinate(point.y))
        end

        def round_coordinate(value)
          Integer(value.round)
        end

        def midpoint(first, second)
          (first + second) * 0.5
        end

        def distance(first, second)
          Math.sqrt((first.x - second.x)**2 + (first.y - second.y)**2)
        end

        def cubic_approximation_error(first_delta, second_delta)
          [first_delta, second_delta].map do |delta|
            distance(delta, Point.new(0, 0)) * 0.25
          end.max
        end

        def distance_to_segment(point, start, endpoint)
          segment = endpoint - start
          length_squared = segment.x**2 + segment.y**2

          return distance(point, start) if length_squared.zero?

          parameter = (
            (point.x - start.x) * segment.x + (point.y - start.y) * segment.y
          ) / length_squared
          parameter = 0.0 if parameter.negative?
          parameter = 1.0 if parameter > 1.0
          projection = Point.new(
            start.x + segment.x * parameter,
            start.y + segment.y * parameter,
          )
          distance(point, projection)
        end
      end
    end
  end
end
