# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # Converts CFF cubic Bézier paths into unhinted TrueType simple glyphs.
      class TrueTypePathEncoder
        POINT_LIMIT = 0xFFFF
        CONTOUR_LIMIT = 0x7FFF
        COORDINATE_MIN = -0x8000
        COORDINATE_MAX = 0x7FFF
        MAX_SUBDIVISIONS = 30

        ON_CURVE = 0x01
        X_SHORT = 0x02
        Y_SHORT = 0x04
        X_POSITIVE_OR_SAME = 0x10
        Y_POSITIVE_OR_SAME = 0x20

        Point = Struct.new(:x, :y, :on_curve) do
          def initialize(x, y, on_curve)
            super(Integer(x), Integer(y), on_curve)
          end
        end

        def self.encode(path, tolerance, glyph_id = nil)
          new(path, tolerance, glyph_id).encode
        end

        # Squared conservative maximum distance between a cubic and the two
        # quadratic segments generated at its midpoint. The Bernstein convex
        # hull makes this a bound over the complete t = 0..1 parameter interval.
        def self.continuous_error_squared(curve)
          left, right = midpoint_split(curve)
          [
            single_quadratic_error_squared(left),
            single_quadratic_error_squared(right),
          ].max
        end

        def self.single_quadratic_control(curve)
          p0, p1, p2, p3 = curve
          [
            (3 * p1[0] + 3 * p2[0] - p0[0] - p3[0]) / 4,
            (3 * p1[1] + 3 * p2[1] - p0[1] - p3[1]) / 4,
          ]
        end

        def self.midpoint_split(curve)
          p0, p1, p2, p3 = curve
          middle01 = midpoint(p0, p1)
          middle12 = midpoint(p1, p2)
          middle23 = midpoint(p2, p3)
          middle012 = midpoint(middle01, middle12)
          middle123 = midpoint(middle12, middle23)
          middle = midpoint(middle012, middle123)

          [
            [p0, middle01, middle012, middle],
            [middle, middle123, middle23, p3],
          ]
        end

        def self.midpoint(first, second)
          [(first[0] + second[0]) / 2, (first[1] + second[1]) / 2]
        end

        def self.single_quadratic_error_squared(curve)
          delta = [
            (-curve[0][0] + (3 * curve[1][0]) - (3 * curve[2][0]) + curve[3][0]) / 6,
            (-curve[0][1] + (3 * curve[1][1]) - (3 * curve[2][1]) + curve[3][1]) / 6,
          ]

          ((delta[0] * delta[0]) + (delta[1] * delta[1])) / 12r
        end

        def initialize(path, tolerance, glyph_id = nil)
          @path = path
          @tolerance = Rational(tolerance)
          @glyph_id = glyph_id
          @points = []
          @end_points_of_contours = []
          @x_min = @y_min = @x_max = @y_max = 0
        end

        def encode
          contours = build_contours
          encode_contours(contours)
          validate_limits!

          {
            raw: encode_raw,
            number_of_contours: @end_points_of_contours.length,
            end_points_of_contours: @end_points_of_contours,
            points: @points,
            x_min: @x_min,
            y_min: @y_min,
            x_max: @x_max,
            y_max: @y_max,
          }
        end

        private

        def build_contours
          contours = []
          contour = nil

          @path.commands.each do |command, *arguments|
            case command
            when :move
              contours << contour if contour
              contour = {
                start: rational_point(arguments[0], arguments[1]),
                segments: [],
                explicitly_closed: false,
              }
            when :line
              contour ||= new_contour
              contour[:segments] << [:line, rational_point(arguments[0], arguments[1])]
            when :curve
              contour ||= new_contour
              contour[:segments] << [
                :curve,
                rational_point(arguments[0], arguments[1]),
                rational_point(arguments[2], arguments[3]),
                rational_point(arguments[4], arguments[5]),
              ]
            when :close
              if contour
                contour[:explicitly_closed] = true
                contours << contour
                contour = nil
              end
            end
          end

          contours << contour if contour
          contours
        end

        def new_contour
          {
            start: rational_point(0, 0),
            segments: [],
            explicitly_closed: false,
          }
        end

        def encode_contours(contours)
          contours.each_with_index do |contour, contour_index|
            start = contour[:start]
            current = start
            segments = contour[:segments]

            next if segments.empty?

            append_point(start, true)
            remaining_points = POINT_LIMIT - @points.length

            segments.each_with_index do |segment, segment_index|
              case segment[0]
              when :line
                endpoint = segment[1]
                rounded_endpoint = rounded_point(endpoint)
                error = quantization_error(
                  [rounded_point(current), rounded_endpoint],
                  [current, endpoint],
                )
                assert_within_tolerance!(error, contour_index, segment_index, 'line')
                append_point(rounded_endpoint, true)
                current = endpoint
                remaining_points -= 1
              when :curve
                leaves = quadratic_leaves(
                  [current, *segment[1..]],
                  contour_index,
                  segment_index,
                )
                needed_points = leaves.length + 1
                if remaining_points < needed_points
                  raise_conversion_error!(point_limit_message(contour_index, segment_index))
                end

                leaves.each_with_index do |leaf, index|
                  append_point(leaf[:control], false)

                  current = leaf[:rational_endpoint]
                  remaining_points -= 1
                end

                append_point(rounded_point(leaves.last[:rational_endpoint]), true)
                current = leaves.last[:rational_endpoint]
                remaining_points -= 1
              end
            end

            rounded_start = rounded_point(start)
            last_point = @points.last

            if !contour[:explicitly_closed] && (current != start || @points.length == 1)
              if current != start
                rounded_current = rounded_point(current)
                error = quantization_error([rounded_current, rounded_start], [current, start])
                assert_within_tolerance!(
                  error,
                  contour_index,
                  segments.length,
                  'closing line',
                )
              end

              unless last_point.x == rounded_start[0] && last_point.y == rounded_start[1]
                append_point(rounded_start, true)
              end
            end

            @end_points_of_contours << (@points.length - 1)
          end
        end

        def quadratic_leaves(curve, contour_index, segment_index)
          curves = [curve]

          0.upto(MAX_SUBDIVISIONS) do |depth|
            continuous_error = continuous_error_for_leaves(curves)

            if continuous_error_is_acceptable?(continuous_error)
              leaves = leaves_for_curves(curves)

              if leaves.all? { |leaf| leaf_within_tolerance?(leaf, curve, leaves) }
                return leaves
              end
            end

            if depth == MAX_SUBDIVISIONS || curves.length * 2 > POINT_LIMIT
              raise_conversion_error!(
                "curve #{segment_index} in contour #{contour_index} could not be approximated within #{@tolerance} font units after #{MAX_SUBDIVISIONS} subdivisions",
              )
            end

            curves = curves.flat_map { |subcurve| split_curve(subcurve) }
          end
        end

        def leaves_for_curves(curves)
          curves.map do |curve|
            {
              curve: curve,
              control: quadratic_control(curve),
              rational_endpoint: curve[3],
            }
          end
        end

        def continuous_error_is_acceptable?(continuous_error)
          within_tolerance?(continuous_error, 0)
        end

        def continuous_error_for_leaves(curves)
          squared = curves.map { |curve|
            self.class.single_quadratic_error_squared(curve)
          }.max
          squared.zero? ? 0 : { squared: squared }
        end

        def leaf_within_tolerance?(leaf, original_curve, leaves)
          index = leaves.index(leaf)
          continuous_error = {
            squared: self.class.single_quadratic_error_squared(leaf[:curve]),
          }
          quantization = quantization_error_for_leaf(original_curve, leaves, index)
          within_tolerance?(continuous_error, quantization)
        end

        def quantization_error_for_leaf(curve, leaves, index)
          controls = leaves.map { |leaf| rounded_point(leaf[:control]) }
          leaf = leaves[index]
          exact_start = leaf[:curve][0]
          exact_end = leaf[:curve][3]
          rounded_start =
            if index.zero?
              rounded_point(curve[0])
            else
              midpoint(controls[index - 1], controls[index])
            end
          rounded_end =
            if index == leaves.length - 1
              rounded_point(curve[3])
            else
              midpoint(controls[index], controls[index + 1])
            end

          quantization_error(
            [rounded_start, controls[index], rounded_end],
            [exact_start, leaf[:control], exact_end],
          )
        end

        def quadratic_control(curve)
          self.class.single_quadratic_control(curve)
        end

        def split_curve(curve)
          self.class.midpoint_split(curve)
        end

        def midpoint(first, second)
          self.class.midpoint(first, second)
        end

        def quantization_error(rounded, exact = rounded)
          squared = rounded.each_with_index.map { |point, index|
            squared_norm(subtract(point, exact[index]))
          }.max

          squared.to_r.zero? ? 0 : { squared: squared.to_r }
        end

        def within_tolerance?(continuous_error, quantization_error)
          continuous_squared = bound_squared(continuous_error)
          quantization_squared = bound_squared(quantization_error)
          tolerance_squared = @tolerance * @tolerance
          remainder = tolerance_squared - continuous_squared - quantization_squared

          return false if remainder.negative?
          return true if continuous_squared.zero? || quantization_squared.zero?

          4 * continuous_squared * quantization_squared <= remainder * remainder
        end

        def assert_within_tolerance!(error, contour_index, segment_index, segment_name)
          return if within_tolerance?(0, error)

          raise_conversion_error!(
            "#{segment_name} #{segment_index} in contour #{contour_index} cannot be quantized within #{@tolerance} font units",
          )
        end

        def encode_raw
          return ''.b if @points.empty?

          flags = []
          x_coordinates = ''.b
          y_coordinates = ''.b
          previous_x = 0
          previous_y = 0

          @points.each do |point|
            flag = point.on_curve ? ON_CURVE : 0
            dx = point.x - previous_x
            dy = point.y - previous_y

            x_flag, x_bytes = encode_coordinate_delta(dx, X_SHORT, X_POSITIVE_OR_SAME)
            y_flag, y_bytes = encode_coordinate_delta(dy, Y_SHORT, Y_POSITIVE_OR_SAME)
            flags << (flag | x_flag | y_flag)
            x_coordinates << x_bytes
            y_coordinates << y_bytes
            previous_x = point.x
            previous_y = point.y
          end

          ''.b.tap do |raw|
            raw << [@end_points_of_contours.length].pack('n')
            raw << [@x_min, @y_min, @x_max, @y_max].pack('s>4')
            raw << @end_points_of_contours.pack('n*')
            raw << [0].pack('n')
            raw << flags.pack('C*')
            raw << x_coordinates
            raw << y_coordinates
          end
        end

        def encode_coordinate_delta(delta, short_flag, positive_or_same_flag)
          if delta.zero?
            [positive_or_same_flag, ''.b]
          elsif delta >= -255 && delta <= 255
            if delta > 0
              [short_flag | positive_or_same_flag, [delta].pack('C')]
            else
              [short_flag, [-delta].pack('C')]
            end
          else
            [0, [delta].pack('s>')]
          end
        end

        def add_point(coordinates, on_curve)
          point = Point.new(rounded(coordinates[0]), rounded(coordinates[1]), on_curve)
          @points << point
          update_bounds(point)
          point
        end

        def append_point(coordinates, on_curve)
          if @points.length >= POINT_LIMIT
            raise_conversion_error!("glyph needs more than #{POINT_LIMIT} points")
          end

          add_point(coordinates, on_curve)
        end

        def update_bounds(point)
          validate_coordinate!(point.x)
          validate_coordinate!(point.y)

          if @points.one?
            @x_min = @x_max = point.x
            @y_min = @y_max = point.y
          else
            @x_min = [point.x, @x_min].min
            @x_max = [point.x, @x_max].max
            @y_min = [point.y, @y_min].min
            @y_max = [point.y, @y_max].max
          end
        end

        def validate_coordinate!(value)
          return if value >= COORDINATE_MIN && value <= COORDINATE_MAX

          raise_conversion_error!("coordinate #{value} is outside the signed 16-bit TrueType range")
        end

        def validate_limits!
          return if @end_points_of_contours.empty?

          if @end_points_of_contours.length > CONTOUR_LIMIT
            raise_conversion_error!("glyph has more than #{CONTOUR_LIMIT} contours")
          end

          return unless @points.length > POINT_LIMIT

          raise_conversion_error!("glyph needs more than #{POINT_LIMIT} points")
        end

        def rounded_point(point)
          [rounded(point[0]), rounded(point[1])]
        end

        def rounded(value)
          Rational(value).round
        end

        def rational_point(x, y)
          [Rational(x), Rational(y)]
        end

        def subtract(first, second)
          [first[0] - second[0], first[1] - second[1]]
        end

        def squared_norm(point)
          (point[0] * point[0]) + (point[1] * point[1])
        end

        def bound_squared(bound)
          bound.is_a?(Hash) ? bound.fetch(:squared) : 0
        end

        def point_limit_message(contour_index, segment_index)
          "curve #{segment_index} in contour #{contour_index} needs more than #{POINT_LIMIT} points at tolerance #{@tolerance}"
        end

        def raise_conversion_error!(reason)
          prefix = "Unable to convert glyph #{@glyph_id || '?'} to TrueType outlines: "
          raise PathBased::ConversionError, prefix + reason
        end
      end
    end
  end
end
