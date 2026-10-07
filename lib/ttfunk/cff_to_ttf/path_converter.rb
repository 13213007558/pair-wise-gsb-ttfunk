# frozen_string_literal: true

module TTFunk
  module CffToTtf
    # Converts an interpreted CFF path (cubic Bezier segments) into TrueType
    # quadratic contours with a guaranteed maximum deviation from the
    # original outline.
    #
    # Each cubic segment is approximated by the quadratic segment that shares
    # its endpoints and its midpoint. For a cubic with control points P0..P3
    # the parametric (and therefore geometric) deviation of that quadratic is
    # bounded by:
    #
    #     err <= (sqrt(3) / 36) * |P0 - 3*P1 + 3*P2 - P3|
    #
    # Segments whose bound exceeds the tolerance are split in half (de
    # Casteljau) and processed recursively; every split shrinks the bound by a
    # factor of 8. Recursion is limited by +max_depth+ which also caps the
    # number of generated segments at 2**max_depth per cubic segment.
    #
    # The caller-provided +max_error+ is the total allowed deviation in font
    # units. Part of that budget is reserved for rounding point coordinates to
    # integers (as required by the +glyf+ table format) and for snapping
    # near-degenerate curves to straight lines, so the guarantee applies to
    # the final integer contours, not just the idealized quadratic splines.
    #
    # If the budget cannot be met (e.g. +max_error+ is smaller than the
    # rounding reserve, or the subdivision limit is hit) the result is
    # reported as incomplete and its contours must not be used.
    class PathConverter
      # Maximum of |t(t - 1/2)(t - 1)| on [0, 1]. Multiplied by the magnitude
      # of the cubic's third difference it gives the deviation bound for the
      # midpoint-matching quadratic approximation.
      ERROR_COEFFICIENT = Math.sqrt(3) / 36

      # Maximum displacement of any point on a quadratic segment introduced by
      # rounding its control points to integer coordinates (half a unit per
      # axis, propagated through the Bezier weights which sum to 1).
      ROUNDING_ERROR = Math.sqrt(2) / 2

      # Distance below which a cubic segment whose control points lie on the
      # chord between its endpoints (in order) is treated as a straight line.
      # This value is reserved from the error budget so the guarantee still
      # holds for snapped segments.
      LINE_EPSILON = 1e-6

      # Default maximum subdivision depth. Limits each cubic segment to
      # 2**10 = 1024 quadratic segments.
      DEFAULT_MAX_DEPTH = 10

      # Valid range of glyph point coordinates in the +glyf+ table (FWORD).
      COORDINATE_RANGE = -0x8000..0x7FFF

      # Result of a path conversion.
      class Result
        # Converted contours. Each contour is an array of points, each point
        # is a triple of x, y (Integers, in font units) and a boolean flag
        # telling whether the point is on the curve.
        # @return [Array<Array<Array(Integer, Integer, Boolean)>>]
        attr_reader :contours

        # @param contours [Array]
        # @param complete [Boolean]
        def initialize(contours:, complete:)
          @contours = contours
          @complete = complete
        end

        # Was the whole path converted within the allowed error?
        #
        # @return [Boolean]
        def complete?
          @complete
        end
      end

      # Maximum allowed deviation in font units, including integer rounding.
      # @return [Float]
      attr_reader :max_error

      # Maximum subdivision depth per cubic segment.
      # @return [Integer]
      attr_reader :max_depth

      # @param max_error [Numeric] maximum allowed deviation in font units.
      # @param max_depth [Integer] maximum cubic subdivision depth.
      def initialize(max_error:, max_depth: DEFAULT_MAX_DEPTH)
        @max_error = max_error
        @max_depth = max_depth
        @tolerance = max_error - ROUNDING_ERROR - LINE_EPSILON
      end

      # Convert a CFF path to quadratic contours.
      #
      # @param path [TTFunk::Table::Cff::Path]
      # @return [Result]
      def convert(path)
        contours = []
        contour = []
        current = nil
        complete = true

        path.commands.each do |command|
          case command[0]
          when :move
            contours << contour unless contour.empty?
            contour = []
            current = [command[1].to_f, command[2].to_f]
            contour << [*current, true]
          when :line
            point = [command[1].to_f, command[2].to_f]
            unless point == current
              contour << [*point, true]
              current = point
            end
          when :curve
            p1 = [command[1].to_f, command[2].to_f]
            p2 = [command[3].to_f, command[4].to_f]
            p3 = [command[5].to_f, command[6].to_f]
            complete = convert_cubic(current, p1, p2, p3, 0, contour) && complete
            current = p3
          when :close
            contours << contour unless contour.empty?
            contour = []
            current = nil
          end
        end
        contours << contour unless contour.empty?

        finalized = finalize(contours)
        complete &&= coordinates_in_range?(finalized)

        Result.new(contours: finalized, complete: complete)
      end

      private

      # Appends quadratic segments approximating the cubic to the contour.
      # Returns false when the error budget cannot be honored.
      def convert_cubic(p0, p1, p2, p3, depth, contour)
        # Zero-length segment.
        return true if p0 == p1 && p1 == p2 && p2 == p3

        if straight_line?(p0, p1, p2, p3)
          contour << [*p3, true]
          return true
        end

        if @tolerance.positive? && cubic_error(p0, p1, p2, p3) <= @tolerance
          append_quadratic(p0, p1, p2, p3, contour)
          return true
        end

        return false if depth >= max_depth

        # Split the cubic in half (de Casteljau) and convert each part.
        q0 = midpoint(p0, p1)
        q1 = midpoint(p1, p2)
        q2 = midpoint(p2, p3)
        r0 = midpoint(q0, q1)
        r1 = midpoint(q1, q2)
        mid = midpoint(r0, r1)

        convert_cubic(p0, q0, r0, mid, depth + 1, contour) &&
          convert_cubic(mid, r1, q2, p3, depth + 1, contour)
      end

      # Deviation bound for the midpoint-matching quadratic approximation of
      # the given cubic segment.
      def cubic_error(p0, p1, p2, p3)
        ERROR_COEFFICIENT * Math.hypot(
          p0[0] - (3 * p1[0]) + (3 * p2[0]) - p3[0],
          p0[1] - (3 * p1[1]) + (3 * p2[1]) - p3[1],
        )
      end

      # Quadratic through the cubic's endpoints and midpoint: its control
      # point is (3*(P1 + P2) - (P0 + P3)) / 4.
      def append_quadratic(p0, p1, p2, p3, contour)
        contour << [
          ((3 * (p1[0] + p2[0])) - p0[0] - p3[0]) / 4.0,
          ((3 * (p1[1] + p2[1])) - p0[1] - p3[1]) / 4.0,
          false,
        ]
        contour << [*p3, true]
      end

      # A cubic is treated as a straight line when both control points lie on
      # the chord between its endpoints (within LINE_EPSILON) and appear along
      # it in order. The ordering check keeps cusps and backtracking curves
      # from being collapsed into a chord.
      def straight_line?(p0, p1, p2, p3)
        dx = p3[0] - p0[0]
        dy = p3[1] - p0[1]
        length_squared = (dx * dx) + (dy * dy)

        # A closed loop, not a line.
        return false if length_squared.zero?

        cross1 = ((p1[0] - p0[0]) * dy) - ((p1[1] - p0[1]) * dx)
        cross2 = ((p2[0] - p0[0]) * dy) - ((p2[1] - p0[1]) * dx)
        epsilon_squared = (LINE_EPSILON**2) * length_squared

        return false if (cross1 * cross1) > epsilon_squared
        return false if (cross2 * cross2) > epsilon_squared

        dot1 = ((p1[0] - p0[0]) * dx) + ((p1[1] - p0[1]) * dy)
        dot2 = ((p2[0] - p0[0]) * dx) + ((p2[1] - p0[1]) * dy)

        dot1 >= 0 && dot2 >= 0 && dot1 <= length_squared &&
          dot2 <= length_squared && dot1 <= dot2
      end

      def midpoint(a, b)
        [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
      end

      # Round coordinates to integers and clean up degenerate artifacts.
      def finalize(contours)
        contours.filter_map do |contour|
          rounded = contour.map { |x, y, on| [x.round, y.round, on] }
          cleaned = cleanup(rounded)
          cleaned unless cleaned.length < 2
        end
      end

      # Drop points that collapsed onto their neighbors during rounding.
      # Dropping an off-curve point that coincides with an adjacent on-curve
      # point turns the segment into the same straight line it already
      # describes, so this doesn't change the outline.
      def cleanup(contour)
        points = contour.each_with_object([]) do |point, kept|
          if kept.last && kept.last[0] == point[0] && kept.last[1] == point[1]
            # Keep the on-curve one of a duplicate pair.
            kept[-1] = point if point[2]
          else
            kept << point
          end
        end

        # Contours are implicitly closed; drop a duplicated closing point.
        if points.length > 1 && points.first[0] == points.last[0] &&
            points.first[1] == points.last[1]
          points.pop
        end

        points
      end

      # Coordinates must fit into the signed 16-bit fields of the +glyf+
      # table.
      def coordinates_in_range?(contours)
        contours.all? { |contour|
          contour.all? { |x, y, _on_curve|
            COORDINATE_RANGE.cover?(x) && COORDINATE_RANGE.cover?(y)
          }
        }
      end
    end
  end
end
