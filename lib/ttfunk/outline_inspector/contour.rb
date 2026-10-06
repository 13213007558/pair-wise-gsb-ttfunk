# frozen_string_literal: true

module TTFunk
  class OutlineInspector
    # A single closed contour expanded from TrueType outline points into
    # line and quadratic Bézier segments.
    class Contour
      # Raw points of the contour as [x, y, on_curve] triples.
      # @return [Array]
      attr_reader :points

      # Expanded segments of the contour.
      # @return [Array<LineSegment, QuadSegment>]
      attr_reader :segments

      # @param points [Array] contour points as [x, y, on_curve] triples
      def initialize(points)
        @points = points
        @segments = self.class.build_segments(points)
      end

      # True signed area enclosed by the contour, integrated analytically
      # over the actual curve segments. Positive for counterclockwise
      # contours, negative for clockwise ones (in a y-up coordinate
      # system).
      #
      # @return [Float]
      def signed_area
        @signed_area ||= segments.sum(&:signed_area)
      end

      # Winding direction of the contour based on the true signed area.
      #
      # @param area_tol [Float] areas with absolute value below this are
      #   considered degenerate
      # @return [Symbol] :clockwise, :counterclockwise, or :degenerate
      def direction(area_tol)
        return :degenerate if signed_area.abs <= area_tol

        signed_area.positive? ? :counterclockwise : :clockwise
      end

      # Axis-aligned bounding box of the contour:
      # [min_x, min_y, max_x, max_y].
      #
      # @return [Array(Float, Float, Float, Float), nil]
      def bbox
        return nil if segments.empty?

        boxes = segments.map(&:bbox)
        [
          boxes.map { |box| box[0] }.min,
          boxes.map { |box| box[1] }.min,
          boxes.map { |box| box[2] }.max,
          boxes.map { |box| box[3] }.max,
        ]
      end

      # Candidate points strictly on the contour (mid-segment), used as
      # probe points for containment tests.
      #
      # @return [Array]
      def probe_points
        probes = []
        segments.each { |segment| probes << segment.evaluate(0.5) }
        segments.each do |segment|
          probes << segment.evaluate(0.25) << segment.evaluate(0.75)
        end
        probes
      end

      # Expand TrueType contour points into segments, inserting implied
      # on-curve points between consecutive off-curve points.
      #
      # @param points [Array] contour points as [x, y, on_curve] triples
      # @return [Array<LineSegment, QuadSegment>]
      def self.build_segments(points)
        pts = points.map { |x, y, on| [x.to_f, y.to_f, !!on] }
        return [] if pts.length < 2

        # Start at an on-curve point. If the contour has none, the first
        # on-curve point is implied between the last and first off-curve
        # points.
        start_index = pts.index { |point| point[2] }
        ordered =
          if start_index
            pts.rotate(start_index)
          else
            mid = Vec.lerp(pts[-1], pts[0], 0.5)
            [[mid[0], mid[1], true]] + pts
          end

        # Close the contour back at the starting on-curve point.
        sequence = ordered + [ordered[0]]

        segments = []
        current = sequence[0]
        index = 1
        while index < sequence.length
          point = sequence[index]
          if point[2]
            segments << LineSegment.new(current[0..1], point[0..1])
            current = point
            index += 1
          else
            nxt = sequence[index + 1]
            if nxt[2]
              segments << QuadSegment.new(current[0..1], point[0..1], nxt[0..1])
              current = nxt
              index += 2
            else
              implied = Vec.lerp(point, nxt, 0.5)
              implied = [implied[0], implied[1], true]
              segments << QuadSegment.new(current[0..1], point[0..1], implied[0..1])
              current = implied
              index += 1
            end
          end
        end
        # Drop degenerate zero-length segments: they enclose nothing and
        # only produce phantom contacts between their neighbors.
        segments.reject { |segment| degenerate?(segment) }
      end

      # Is the segment collapsed to a single point?
      def self.degenerate?(segment)
        case segment
        when LineSegment
          segment.p0 == segment.p1
        when QuadSegment
          segment.p0 == segment.c && segment.c == segment.p1
        else
          false
        end
      end
    end
  end
end
