# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # Encoded simple TrueType outline produced from interpreted paths.
      class SimpleOutline
        ON_CURVE_POINT = 0x01
        X_SHORT_VECTOR = 0x02
        Y_SHORT_VECTOR = 0x04
        X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR = 0x10
        Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR = 0x20
        OVERLAP_SIMPLE = 0x40

        attr_reader :contours, :number_of_contours, :end_points_of_contours
        attr_reader :x_min, :y_min, :x_max, :y_max
        attr_reader :instruction_length, :instructions, :max_error

        def self.from_path(path, max_error:, max_segments: CubicToQuadratic::DEFAULT_MAX_SEGMENTS_PER_CURVE)
          new(
            CubicToQuadratic.convert(
              path,
              max_error: max_error,
              max_segments: max_segments,
            ),
          )
        end

        def initialize(result)
          @contours = result.contours
          @number_of_contours = contours.count
          @max_error = result.max_error
          @instruction_length = 0
          @instructions = []
          @end_points_of_contours = []

          point_count = 0
          contours.each do |contour|
            point_count += contour.sum { |segment| segment.points.count }
            @end_points_of_contours << point_count - 1
          end

          points = contours.flat_map do |contour|
            contour.flat_map do |segment|
              segment.points.each_with_index.map do |point, index|
                on_curve =
                  segment.type == :line ||
                    index == segment.points.count - 1
                [point, on_curve]
              end
            end
          end

          coordinates = points.map(&:first)
          @x_min, @x_max = coordinates.empty? ? [0, 0] : coordinates.map(&:x).minmax
          @y_min, @y_max = coordinates.empty? ? [0, 0] : coordinates.map(&:y).minmax
          @raw = encode(points, first_overlap: contours.any?)
        end

        def compound?
          false
        end

        def recode(_mapping)
          @raw
        end

        def end_point_of_last_contour
          end_points_of_contours.empty? ? 0 : end_points_of_contours.last + 1
        end

        private

        def encode(points, first_overlap:)
          return '' if number_of_contours.zero?

          table = [
            number_of_contours,
            x_min, y_min, x_max, y_max,
            *end_points_of_contours,
            instruction_length,
          ].pack('s>*')

          flags = []
          x_coordinates = []
          y_coordinates = []
          previous_x = 0
          previous_y = 0
          points.each do |point, on_curve|
            x_delta = point.x - previous_x
            y_delta = point.y - previous_y
            ensure_int16!(x_delta, 'x')
            ensure_int16!(y_delta, 'y')
            flags <<
              flag_for(
                on_curve,
                x_delta,
                y_delta,
                first_point: flags.empty? && first_overlap,
              )
            append_delta(x_coordinates, x_delta, x: true)
            append_delta(y_coordinates, y_delta, x: false)
            previous_x = point.x
            previous_y = point.y
          end

          table << encode_flags(flags)
          table << x_coordinates.join
          table << y_coordinates.join
          table
        end

        def ensure_int16!(value, axis)
          return if value.between?(-32_768, 32_767)

          raise ArgumentError, "glyph #{axis} coordinate is outside signed 16-bit range"
        end

        def flag_for(on_curve, x_delta, y_delta, first_point:)
          flag = on_curve ? ON_CURVE_POINT : 0
          flag |= OVERLAP_SIMPLE if first_point

          flag =
            apply_delta_flags(
              flag,
              x_delta,
              X_SHORT_VECTOR,
              X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR,
            )
          apply_delta_flags(
            flag,
            y_delta,
            Y_SHORT_VECTOR,
            Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR,
          )
        end

        def apply_delta_flags(flag, delta, short_flag, same_flag)
          if delta.zero?
            flag | same_flag
          elsif delta.abs < 256
            flag | short_flag | (delta.positive? ? same_flag : 0)
          else
            flag
          end
        end

        def append_delta(coordinates, delta, x:)
          if delta.zero?
            # The same flag makes this an implicit zero.
          elsif delta.abs < 256
            coordinates << [delta.abs].pack('C')
          else
            coordinates << [delta].pack('s>')
          end
        end

        def encode_flags(flags)
          flags.pack('C*')
        end
      end
    end
  end
end
