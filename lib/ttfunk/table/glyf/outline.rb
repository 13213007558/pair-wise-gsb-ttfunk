# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # Fully expanded glyph outline. Compound glyphs are resolved to their
      # component points with all transformations applied.
      class Outline
        # Glyph points as [x, y] pairs. Point numbering follows the order
        # in which components are expanded. Coordinates can be fractional
        # when a component transformation produced them.
        # @return [Array<Array(Numeric, Numeric)>]
        attr_reader :points

        # Indices of the last point of each contour.
        # @return [Array<Integer>]
        attr_reader :end_points_of_contours

        # On-curve flag for each point (true for on-curve, false for
        # off-curve control points).
        # @return [Array<Boolean>]
        attr_reader :on_curve

        # Effective advance width. For compound glyphs this honors the
        # USE_MY_METRICS component flag.
        # @return [Integer]
        attr_reader :advance_width

        # Effective left side bearing. For compound glyphs this honors the
        # USE_MY_METRICS component flag.
        # @return [Integer]
        attr_reader :left_side_bearing

        # @param points [Array<Array(Numeric, Numeric)>]
        # @param end_points_of_contours [Array<Integer>]
        # @param on_curve [Array<Boolean>]
        # @param advance_width [Integer]
        # @param left_side_bearing [Integer]
        def initialize(
          points:, end_points_of_contours:, on_curve:,
          advance_width:, left_side_bearing:
        )
          @points = points
          @end_points_of_contours = end_points_of_contours
          @on_curve = on_curve
          @advance_width = advance_width
          @left_side_bearing = left_side_bearing
        end

        # Number of points in the outline.
        # @return [Integer]
        def number_of_points
          points.length
        end

        # Number of contours in the outline.
        # @return [Integer]
        def number_of_contours
          end_points_of_contours.length
        end
      end
    end
  end
end
