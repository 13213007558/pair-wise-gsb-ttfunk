# frozen_string_literal: true

module TTFunk
  class OutlineInspector
    # 2D vector helpers operating on (x, y) pairs.
    module Vec
      module_function

      def sub(a, b)
        [a[0] - b[0], a[1] - b[1]]
      end

      def scale(a, factor)
        [a[0] * factor, a[1] * factor]
      end

      def cross(a, b)
        (a[0] * b[1]) - (a[1] * b[0])
      end

      def dot(a, b)
        (a[0] * b[0]) + (a[1] * b[1])
      end

      def norm(a)
        Math.sqrt(dot(a, a))
      end

      def lerp(a, b, t)
        [
          a[0] + ((b[0] - a[0]) * t),
          a[1] + ((b[1] - a[1]) * t),
        ]
      end
    end

    # Straight line segment of an outline.
    class LineSegment
      # Start point.
      # @return [Array(Float, Float)]
      attr_reader :p0

      # End point.
      # @return [Array(Float, Float)]
      attr_reader :p1

      def initialize(p0, p1)
        @p0 = p0
        @p1 = p1
      end

      # Exact contribution of this segment to the signed area of its contour
      # (0.5 * ∮(x dy - y dx)).
      #
      # @return [Float]
      def signed_area
        0.5 * Vec.cross(p0, p1)
      end

      # Point on the segment at parameter t (0..1).
      #
      # @return [Array(Float, Float)]
      def evaluate(t)
        Vec.lerp(p0, p1, t)
      end

      # Tangent vector at parameter t.
      #
      # @return [Array(Float, Float)]
      def derivative(_t)
        Vec.sub(p1, p0)
      end

      # Segment length.
      #
      # @return [Float]
      def length
        Vec.norm(derivative(0))
      end

      # Axis-aligned bounding box: [min_x, min_y, max_x, max_y].
      #
      # @return [Array(Float, Float, Float, Float)]
      def bbox
        [
          [p0[0], p1[0]].min, [p0[1], p1[1]].min,
          [p0[0], p1[0]].max, [p0[1], p1[1]].max,
        ]
      end

      # Number of times a horizontal ray cast from point towards +x crosses
      # this segment. Returns :uncertain when the ray passes (within tol)
      # through an endpoint or through the point itself, making the crossing
      # count ambiguous.
      #
      # @return [Integer, Symbol]
      def ray_crossings(point, tol)
        px, py = point
        x0, y0 = p0
        x1, y1 = p1

        return :uncertain if (y0 - py).abs <= tol || (y1 - py).abs <= tol
        return 0 if (y0 < py) == (y1 < py)

        x = x0 + (((py - y0) / (y1 - y0)) * (x1 - x0))
        return :uncertain if (x - px).abs <= tol

        x > px ? 1 : 0
      end
    end

    # Quadratic Bézier segment of an outline as used by TrueType glyphs.
    class QuadSegment
      # Start point (on-curve).
      # @return [Array(Float, Float)]
      attr_reader :p0

      # Control point (off-curve).
      # @return [Array(Float, Float)]
      attr_reader :c

      # End point (on-curve).
      # @return [Array(Float, Float)]
      attr_reader :p1

      def initialize(p0, c, p1)
        @p0 = p0
        @c = c
        @p1 = p1
      end

      # Exact contribution of this segment to the signed area of its contour
      # (0.5 * ∮(x dy - y dx)), integrated analytically over the curve
      # itself. This deliberately differs from the area of the control
      # polygon: for a quadratic Bézier the integral of (x dy - y dx) is
      # 2/3 cross(P0,C) + 1/3 cross(P0,P1) + 2/3 cross(C,P1).
      #
      # @return [Float]
      def signed_area
        (Vec.cross(p0, c) / 3.0) +
          (Vec.cross(p0, p1) / 6.0) +
          (Vec.cross(c, p1) / 3.0)
      end

      # Point on the curve at parameter t (0..1).
      #
      # @return [Array(Float, Float)]
      def evaluate(t)
        mt = 1 - t
        [
          (mt * mt * p0[0]) + (2 * mt * t * c[0]) + (t * t * p1[0]),
          (mt * mt * p0[1]) + (2 * mt * t * c[1]) + (t * t * p1[1]),
        ]
      end

      # Tangent vector at parameter t.
      #
      # @return [Array(Float, Float)]
      def derivative(t)
        mt = 1 - t
        [
          (2 * mt * (c[0] - p0[0])) + (2 * t * (p1[0] - c[0])),
          (2 * mt * (c[1] - p0[1])) + (2 * t * (p1[1] - c[1])),
        ]
      end

      # The chord connecting the curve endpoints, as a segment.
      #
      # @return [LineSegment]
      def chord
        LineSegment.new(p0, p1)
      end

      # Axis-aligned bounding box of the curve itself (not of the control
      # polygon): [min_x, min_y, max_x, max_y].
      #
      # @return [Array(Float, Float, Float, Float)]
      def bbox
        min_x, max_x = [p0[0], p1[0]].minmax
        min_y, max_y = [p0[1], p1[1]].minmax

        t_x = extremum_t(0)
        if t_x
          x = evaluate(t_x)[0]
          min_x = x if x < min_x
          max_x = x if x > max_x
        end

        t_y = extremum_t(1)
        if t_y
          y = evaluate(t_y)[1]
          min_y = y if y < min_y
          max_y = y if y > max_y
        end

        [min_x, min_y, max_x, max_y]
      end

      # Is the curve within tol of its chord?
      def flat?(tol)
        chord_vec = Vec.sub(p1, p0)
        len = Vec.norm(chord_vec)

        if len <= tol
          Vec.norm(Vec.sub(c, p0)) <= tol
        else
          Vec.cross(chord_vec, Vec.sub(c, p0)).abs / len <= tol
        end
      end

      # Split the curve at t = 0.5 (de Casteljau).
      #
      # @return [Array(QuadSegment, QuadSegment)]
      def subdivide
        m01 = Vec.lerp(p0, c, 0.5)
        m12 = Vec.lerp(c, p1, 0.5)
        m012 = Vec.lerp(m01, m12, 0.5)

        [
          QuadSegment.new(p0, m01, m012),
          QuadSegment.new(m012, m12, p1),
        ]
      end

      # Number of times a horizontal ray cast from point towards +x crosses
      # this curve. Returns :uncertain when the ray is (within tol) tangent
      # to the curve, passes through an endpoint, or passes through the
      # point itself.
      #
      # @return [Integer, Symbol]
      def ray_crossings(point, tol)
        px, py = point

        return :uncertain if (p0[1] - py).abs <= tol || (p1[1] - py).abs <= tol

        # Solve y(t) = py.
        a = p0[1] - (2 * c[1]) + p1[1]
        b = 2 * (c[1] - p0[1])
        d = p0[1] - py

        roots =
          if a.abs <= tol && b.abs <= tol
            # The whole curve lies on a horizontal line.
            return :uncertain if d.abs <= tol
            return 0
          elsif a.abs <= tol
            [-d / b]
          else
            disc = (b * b) - (4 * a * d)
            return 0 if disc < -(tol * tol)
            # The ray grazes the curve: the crossing count is ambiguous.
            return :uncertain if disc.abs <= tol * tol

            sqrt = Math.sqrt(disc)
            [(-b + sqrt) / (2 * a), (-b - sqrt) / (2 * a)]
          end

        crossings = 0
        roots.each do |t|
          # Half-open interval (0, 1] so vertices shared by consecutive
          # segments are counted exactly once.
          next if t <= 0 || t > 1

          x = evaluate(t)[0]
          return :uncertain if (x - px).abs <= tol

          crossings += 1 if x > px
        end
        crossings
      end

      private

      def extremum_t(axis)
        denom = p0[axis] - (2 * c[axis]) + p1[axis]
        return nil if denom.zero?

        t = (p0[axis] - c[axis]) / denom
        t.between?(0, 1) ? t : nil
      end
    end
  end
end
