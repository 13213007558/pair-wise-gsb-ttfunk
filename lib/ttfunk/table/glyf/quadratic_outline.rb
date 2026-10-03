# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # Converts a CFF-style path to an unhinted TrueType simple glyph.
      class QuadraticOutline
        MAX_CONTOURS = 0xFFFF
        MAX_POINTS = 0xFFFF
        COORDINATE_LIMIT = 32_767
        FLAG_ON_CURVE = 0x01
        FLAG_X_SHORT = 0x02
        FLAG_Y_SHORT = 0x04
        FLAG_REPEAT = 0x08
        FLAG_X_SAME_OR_POSITIVE = 0x10
        FLAG_Y_SAME_OR_POSITIVE = 0x20
        OVERLAP_SIMPLE = 0x40

        Point = Struct.new(:x, :y, :on_curve, keyword_init: true)
        Contour = Struct.new(:points, :cubic_segments, :start, keyword_init: true)

        attr_reader :contours, :tolerance, :glyph_id

        def self.from_path(path, tolerance, glyph_id: nil)
          new(path, tolerance, glyph_id).convert
        end

        def initialize(path, tolerance, glyph_id = nil)
          @path = path
          @glyph_id = glyph_id

          unless tolerance.is_a?(Numeric)
            raise TTFunk::Error, 'quadratic tolerance must be a positive number'
          end

          @tolerance = Rational(tolerance)
          unless @tolerance.positive?
            raise TTFunk::Error, 'quadratic tolerance must be positive'
          end

          @contours = []
          @rounded = {}
          @point_count = 0
        end

        def convert
          build_contours
          self
        end

        def number_of_contours
          contours.length
        end

        def end_point_of_last_contour
          contours.sum { |contour| contour.points.length }
        end
        alias points_count end_point_of_last_contour

        def instruction_length
          0
        end

        def x_min
          bounds&.first || 0
        end

        def y_min
          bounds&.fetch(1) || 0
        end

        def x_max
          bounds&.fetch(2) || 0
        end

        def y_max
          bounds&.fetch(3) || 0
        end

        def recode
          return +'' if contours.empty?

          table = +''
          table << [
            number_of_contours,
            x_min, y_min, x_max, y_max,
          ].pack('n5')

          end_point = -1
          contours.each do |contour|
            end_point += contour.points.length
            table << [end_point].pack('n')
          end

          table << [instruction_length].pack('n')
          append_coordinates(table)
          table
        end

        def self.cubic_to_quadratic(p0, p1, p2, p3, tolerance, interval = 0...1)
          result = new(nil, tolerance)
          contour = result.send(:new_contour)
          points = [p0, p1, p2, p3].map { |coordinates| result.send(:point, *coordinates) }
          result.send(:append_cubic, contour, *points, interval)
          contour.cubic_segments
        end

        private

        def build_contours
          current = nil

          @path.commands.each do |command|
            case command.first
            when :move
              finish_contour(current)
              start = point(command[1], command[2])
              current = new_contour(start)
              add_point(current, rounded_point(start), true)
            when :line
              current ||= new_contour
              append_line(current, point(command[1], command[2]))
            when :curve
              current ||= new_contour
              append_cubic(
                current,
                current.points.last,
                point(command[1], command[2]),
                point(command[3], command[4]),
                point(command[5], command[6]),
              )
            when :close
              finish_contour(current)
              current = nil
            end
          end

          finish_contour(current)
        end

        def new_contour(start = nil)
          Contour.new(points: [], cubic_segments: [], start: start)
        end

        def finish_contour(contour)
          return unless contour
          return if contour.points.empty?

          if contour.start &&
              !same_point?(contour.points.last, rounded_point(contour.start))
            append_line(contour, contour.start)
          end

          removed_points = 0
          while contour.points.length > 1 && same_point?(contour.points.first, contour.points.last)
            contour.points.pop
            removed_points += 1
          end
          removed_points += 1 if contour.points.one?
          @point_count -= removed_points

          if contour.points.length > 1
            if @contours.length >= MAX_CONTOURS
              fail_conversion!('glyph exceeds the TrueType contour limit')
            end

            @contours << contour
          end
        end

        def append_line(contour, endpoint)
          start = contour.points.last
          return if same_point?(start, endpoint)

          quant = rounded_point(endpoint)
          if squared_distance(endpoint, quant) > tolerance_squared
            fail_conversion!('integer coordinate quantization exceeds tolerance')
          end

          add_point(contour, quant, true)
        end

        def append_cubic(contour, p0, p1, p2, p3, interval = 0...1)
          return if [p1, p2, p3].all? { |point| same_point?(p0, point) }

          q0 = rounded_point(p0)
          q3 = rounded_point(p3)
          unless squared_distance(p0, q0) <= tolerance_squared &&
              squared_distance(p3, q3) <= tolerance_squared
            fail_conversion!('endpoint coordinate quantization exceeds tolerance')
          end

          q1 = rounded_point(quadratic_control(p0, p1, p2, p3))
          within = cubic_within?(p0, p1, p2, p3, q0, q1, q3)
          return add_quadratic(contour, p0, p1, p2, p3, q1, q3, interval) if within

          a = midpoint(p0, p1)
          b = midpoint(p1, p2)
          c = midpoint(p2, p3)
          d = midpoint(a, b)
          e = midpoint(b, c)
          middle = midpoint(d, e)
          middle_time = (interval.begin + interval.end) / 2

          append_cubic(contour, p0, a, d, middle, interval.begin...middle_time)
          append_cubic(contour, middle, e, c, p3, middle_time...interval.end)
        end

        def add_quadratic(contour, p0, p1, p2, p3, q1, q3, interval)
          segment = {
            cubic: [p0, p1, p2, p3],
            quadratic: [rounded_point(p0), q1, q3],
            interval: interval,
          }
          contour.cubic_segments << segment
          add_point(contour, q1, false)
          add_point(contour, q3, true)
        end

        def cubic_within?(p0, p1, p2, p3, q0, q1, q3)
          elevated = [
            q0,
            Point.new(x: Rational(1, 3) * q0.x + Rational(2, 3) * q1.x,
                      y: Rational(1, 3) * q0.y + Rational(2, 3) * q1.y),
            Point.new(x: Rational(2, 3) * q1.x + Rational(1, 3) * q3.x,
                      y: Rational(2, 3) * q1.y + Rational(1, 3) * q3.y),
            q3,
          ]

          controls = [p0, p1, p2, p3].each_with_index.map do |point, index|
            Point.new(x: point.x - elevated[index].x, y: point.y - elevated[index].y)
          end
          limit = tolerance * tolerance
          squared_bounds(controls).all? { |value| value <= limit }
        end

        def tolerance_squared
          @tolerance_squared ||= tolerance * tolerance
        end

        def squared_bounds(controls)
          x0, x1, x2, x3 = controls.map(&:x)
          y0, y1, y2, y3 = controls.map(&:y)
          x = [x0, x1, x2, x3]
          y = [y0, y1, y2, y3]

          degree6_counts = [1, 6, 15, 20, 15, 6, 1]

          Array.new(7) do |index|
            x_sum = bernstein_products(x, index, degree6_counts[index]).sum
            y_sum = bernstein_products(y, index, degree6_counts[index]).sum
            x_sum + y_sum
          end
        end

        def bernstein_products(values, degree, degree6_count)
          cubic_counts = [1, 3, 3, 1]

          (0..3).filter_map do |i|
            j = degree - i
            next if j.negative? || j > 3

            Rational(cubic_counts[i] * cubic_counts[j], degree6_count) *
              values[i] * values[j]
          end
        end

        def add_point(contour, point, on_curve)
          contour.points << Point.new(
            x: point.x,
            y: point.y,
            on_curve: on_curve,
          )
          @point_count += 1
          validate_point_limit!
        end

        def validate_point_limit!
          fail_conversion!('glyph exceeds the TrueType point limit') if @point_count > MAX_POINTS
        end

        def point(x, y)
          Point.new(x: Rational(x), y: Rational(y))
        end

        def rounded_point(point)
          key = [point.x, point.y]
          @rounded.fetch(key) do
            x = round_rational(point.x)
            y = round_rational(point.y)
            unless x.abs <= COORDINATE_LIMIT && y.abs <= COORDINATE_LIMIT
              fail_conversion!('coordinate is outside the signed 16-bit TrueType range')
            end

            @rounded[key] = Point.new(x: x, y: y)
          end
        end

        def round_rational(value)
          floor = value.floor
          fraction = value - floor
          return floor if fraction < Rational(1, 2)
          return floor + 1 if fraction > Rational(1, 2)
          floor.even? ? floor : floor + 1
        end

        def midpoint(first, second)
          Point.new(
            x: Rational(1, 2) * (first.x + second.x),
            y: Rational(1, 2) * (first.y + second.y),
          )
        end

        def same_point?(first, second)
          first.x == second.x && first.y == second.y
        end

        def squared_distance(first, second)
          (second.x - first.x)**2 + (second.y - first.y)**2
        end

        def quadratic_control(p0, p1, p2, p3)
          Point.new(
            x: Rational(3, 4) * (p1.x + p2.x) - Rational(1, 4) * (p0.x + p3.x),
            y: Rational(3, 4) * (p1.y + p2.y) - Rational(1, 4) * (p0.y + p3.y),
          )
        end

        def fail_conversion!(reason)
          identifier = glyph_id ? " glyph #{glyph_id}:" : ':'
          raise TTFunk::Error, "cannot convert CFF outline#{identifier} #{reason}"
        end

        def bounds
          @bounds ||=
            if contours.empty?
              nil
            else
              values = contours.flat_map(&:points)
              [
                values.map(&:x).min,
                values.map(&:y).min,
                values.map(&:x).max,
                values.map(&:y).max,
              ]
            end
        end

        def append_coordinates(table)
          previous_x = 0
          previous_y = 0
          flags = []
          x_coordinates = []
          y_coordinates = []

          contours.flat_map(&:points).each do |point|
            dx = point.x - previous_x
            dy = point.y - previous_y
            flags << coordinate_flag(
              point.on_curve ? FLAG_ON_CURVE : 0,
              dx, dy, x_coordinates, y_coordinates,
            )
            previous_x = point.x
            previous_y = point.y
          end

          append_flags(table, flags)
          table << x_coordinates.pack('C*')
          table << y_coordinates.pack('C*')
        end

        def coordinate_flag(base_flag, dx, dy, x_coordinates, y_coordinates)
          flag = OVERLAP_SIMPLE | base_flag

          if dx.zero?
            flag |= FLAG_X_SAME_OR_POSITIVE
          elsif dx.abs <= 255
            flag |= FLAG_X_SHORT
            x_coordinates << dx.abs
            flag |= FLAG_X_SAME_OR_POSITIVE if dx.positive?
          elsif dx.abs <= 32_767
            x_coordinates.concat([dx].pack('s>').bytes)
            flag |= FLAG_X_SAME_OR_POSITIVE unless dx.negative?
          else
            fail_conversion!('TrueType coordinate delta is outside signed 16-bit range')
          end

          if dy.zero?
            flag |= FLAG_Y_SAME_OR_POSITIVE
          elsif dy.abs <= 255
            flag |= FLAG_Y_SHORT
            y_coordinates << dy.abs
            flag |= FLAG_Y_SAME_OR_POSITIVE if dy.positive?
          elsif dy.abs <= 32_767
            y_coordinates.concat([dy].pack('s>').bytes)
            flag |= FLAG_Y_SAME_OR_POSITIVE unless dy.negative?
          else
            fail_conversion!('TrueType coordinate delta is outside signed 16-bit range')
          end

          flag
        end

        def append_flags(table, flags)
          index = 0
          while index < flags.length
            run = 1
            run += 1 while
              index + run < flags.length &&
              flags[index + run] == flags[index] &&
              run < 255

            if run > 1
              table << [flags[index] | FLAG_REPEAT, run].pack('C2')
            else
              table << flags[index].chr
            end
            index += run
          end
        end
      end
    end
  end
end
