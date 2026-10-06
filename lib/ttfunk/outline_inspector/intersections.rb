# frozen_string_literal: true

module TTFunk
  class OutlineInspector
    # Exact intersection tests between outline segments.
    #
    # Line/line and line/quadratic intersections are computed analytically.
    # Quadratic/quadratic intersections are found by recursive de Casteljau
    # subdivision of the actual curves (never by flattening the control
    # polygon), converging on the intersection parameters.
    module Intersections
      # Parameter-space tolerance.
      PARAM_TOL = 1e-9

      # Maximum subdivision depth for curve/curve intersection.
      MAX_DEPTH = 40

      # Merged overlaps shorter than this parameter span are reclassified
      # as tangent touches: a genuine coincidence of edges spans a
      # macroscopic part of a segment, while a tangency converges to a
      # point under subdivision.
      OVERLAP_POINT_TOL = 1e-3

      # A single intersection between two segments.
      #
      # * kind - :crossing, :tangent, or :overlap.
      # * t1, t2 - parameters on the first and second segment. For
      #   :overlap these are Ranges spanning the coincident part.
      # * point - intersection point (start of the coincident part for
      #   :overlap).
      Hit = Struct.new(:kind, :t1, :t2, :point)

      module_function

      # Find all intersections between two segments.
      #
      # @param seg_a [LineSegment, QuadSegment]
      # @param seg_b [LineSegment, QuadSegment]
      # @param tol [Float] absolute geometric tolerance
      # @return [Array<Hit>]
      def between(seg_a, seg_b, tol)
        if seg_a.is_a?(LineSegment) && seg_b.is_a?(LineSegment)
          line_line(seg_a, seg_b, tol)
        elsif seg_a.is_a?(QuadSegment) && seg_b.is_a?(QuadSegment)
          quad_quad(seg_a, seg_b, tol)
        elsif seg_a.is_a?(LineSegment)
          line_quad(seg_a, seg_b, tol)
        else
          line_quad(seg_b, seg_a, tol).map { |hit| swap_hit(hit) }
        end
      end

      # @return [Array<Hit>]
      def line_line(seg_a, seg_b, tol)
        d = Vec.sub(seg_a.p1, seg_a.p0)
        e = Vec.sub(seg_b.p1, seg_b.p0)
        len_d = Vec.norm(d)
        len_e = Vec.norm(e)
        return [] if len_d <= tol || len_e <= tol

        denom = Vec.cross(d, e)
        w = Vec.sub(seg_b.p0, seg_a.p0)

        if denom.abs > tol * len_d * len_e
          t = Vec.cross(w, e) / denom
          u = Vec.cross(w, d) / denom
          return [] unless in_range?(t) && in_range?(u)

          t = t.clamp(0.0, 1.0)
          u = u.clamp(0.0, 1.0)
          [Hit.new(:crossing, t, u, seg_a.evaluate(t))]
        else
          # Parallel: only collinear segments interact.
          return [] if Vec.cross(w, d).abs > tol * len_d

          axis = d[0].abs >= d[1].abs ? 0 : 1
          return [] if d[axis].zero?

          t0 = (seg_b.p0[axis] - seg_a.p0[axis]) / d[axis]
          t1 = (seg_b.p1[axis] - seg_a.p0[axis]) / d[axis]
          lo, hi = [t0, t1].minmax
          ov_lo = [lo, 0.0].max
          ov_hi = [hi, 1.0].min
          return [] if ov_hi < ov_lo - PARAM_TOL

          if ov_hi - ov_lo <= PARAM_TOL
            tm = ((ov_lo + ov_hi) / 2.0).clamp(0.0, 1.0)
            point = seg_a.evaluate(tm)
            [Hit.new(:tangent, tm, project_param(seg_b, point), point)]
          else
            ua = project_param(seg_b, seg_a.evaluate(ov_lo))
            ub = project_param(seg_b, seg_a.evaluate(ov_hi))
            u_min, u_max = [ua, ub].minmax
            [Hit.new(:overlap, ov_lo..ov_hi, u_min..u_max, seg_a.evaluate(ov_lo))]
          end
        end
      end

      # @return [Array<Hit>]
      def line_quad(line, quad, tol)
        d = Vec.sub(line.p1, line.p0)
        len = Vec.norm(d)
        return [] if len <= tol

        # Signed distance of the curve from the line: f(t) = n . (B(t) - P0).
        n = [-d[1] / len, d[0] / len]
        aa = Vec.dot(n, [
          quad.p0[0] - (2 * quad.c[0]) + quad.p1[0],
          quad.p0[1] - (2 * quad.c[1]) + quad.p1[1],
        ])
        bb = 2 * Vec.dot(n, Vec.sub(quad.c, quad.p0))
        cc = Vec.dot(n, Vec.sub(quad.p0, line.p0))

        if aa.abs <= tol && bb.abs <= tol
          return [] if cc.abs > tol

          # The whole curve lies on the line: coincident (overlapping) edge.
          u0 = project_param(line, quad.p0)
          u1 = project_param(line, quad.p1)
          lo, hi = [u0, u1].minmax
          ov_lo = [lo, 0.0].max
          ov_hi = [hi, 1.0].min
          return [] if ov_hi < ov_lo - PARAM_TOL

          if ov_hi - ov_lo <= PARAM_TOL
            um = ((ov_lo + ov_hi) / 2.0).clamp(0.0, 1.0)
            point = line.evaluate(um)
            [Hit.new(:tangent, um, quad_param_at(quad, point), point)]
          else
            t_lo = quad_param_at(quad, line.evaluate(ov_lo))
            t_hi = quad_param_at(quad, line.evaluate(ov_hi))
            t_min, t_max = [t_lo, t_hi].minmax
            [Hit.new(:overlap, ov_lo..ov_hi, t_min..t_max, line.evaluate(ov_lo))]
          end
        elsif aa.abs <= tol
          quad_roots(line, quad, [-cc / bb], false, tol)
        else
          disc = (bb * bb) - (4 * aa * cc)
          return [] if disc < -(tol * tol)

          if disc.abs <= tol * tol
            # The curve just touches the line.
            quad_roots(line, quad, [-bb / (2 * aa)], true, tol)
          else
            sqrt = Math.sqrt(disc)
            quad_roots(
              line, quad,
              [(-bb + sqrt) / (2 * aa), (-bb - sqrt) / (2 * aa)],
              false, tol
            )
          end
        end
      end

      # @return [Array<Hit>]
      def quad_quad(seg_a, seg_b, tol)
        hits = []
        quad_quad_rec(seg_a, seg_b, 0.0..1.0, 0.0..1.0, 0, tol, hits)
        merge_hits(hits, seg_a, seg_b)
      end

      def quad_quad_rec(seg_a, seg_b, range_a, range_b, depth, tol, hits)
        return if depth > MAX_DEPTH
        return unless bbox_overlap?(seg_a.bbox, seg_b.bbox, tol)

        if seg_a.flat?(tol) && seg_b.flat?(tol)
          line_line(seg_a.chord, seg_b.chord, tol).each do |hit|
            hits << remap_hit(hit, range_a, range_b)
          end
          return
        end

        if bbox_extent(seg_a.bbox) >= bbox_extent(seg_b.bbox)
          left, right = seg_a.subdivide
          mid = (range_a.begin + range_a.end) / 2.0
          quad_quad_rec(left, seg_b, range_a.begin..mid, range_b, depth + 1, tol, hits)
          quad_quad_rec(right, seg_b, mid..range_a.end, range_b, depth + 1, tol, hits)
        else
          left, right = seg_b.subdivide
          mid = (range_b.begin + range_b.end) / 2.0
          quad_quad_rec(seg_a, left, range_a, range_b.begin..mid, depth + 1, tol, hits)
          quad_quad_rec(seg_a, right, range_a, mid..range_b.end, depth + 1, tol, hits)
        end
      end

      # Post-process raw subdivision hits: classify tangency of crossings
      # from the actual curve tangents, deduplicate, merge coincident
      # ranges, and reclassify point-sized overlaps as tangent touches.
      #
      # @return [Array<Hit>]
      def merge_hits(hits, seg_a, seg_b)
        points = []
        overlaps = []

        hits.each do |hit|
          if hit.kind == :overlap
            overlaps << hit
          else
            points << hit
          end
        end

        points = dedupe_points(points).map { |hit| classify_tangency(hit, seg_a, seg_b) }
        overlaps = merge_overlaps(overlaps)

        overlaps.each do |hit|
          span_a = hit.t1.end - hit.t1.begin
          span_b = hit.t2.end - hit.t2.begin
          if span_a <= OVERLAP_POINT_TOL || span_b <= OVERLAP_POINT_TOL
            tm = (hit.t1.begin + hit.t1.end) / 2.0
            um = (hit.t2.begin + hit.t2.end) / 2.0
            points << Hit.new(:tangent, tm, um, seg_a.evaluate(tm))
          else
            points << hit
          end
        end

        dedupe_points(points)
      end

      def classify_tangency(hit, seg_a, seg_b)
        return hit unless hit.kind == :crossing

        d1 = seg_a.derivative(hit.t1)
        d2 = seg_b.derivative(hit.t2)
        denom = Vec.norm(d1) * Vec.norm(d2)
        return hit if denom.zero?

        if Vec.cross(d1, d2).abs <= 1e-9 * denom
          Hit.new(:tangent, hit.t1, hit.t2, hit.point)
        else
          hit
        end
      end

      def dedupe_points(hits)
        seen = {}
        hits.each_with_object([]) do |hit, result|
          key =
            if hit.kind == :overlap
              [:overlap, hit.t1.begin.round(6), hit.t1.end.round(6)]
            else
              [hit.kind, hit.t1.round(6), hit.t2.round(6)]
            end
          next if seen[key]

          seen[key] = true
          result << hit
        end
      end

      def merge_overlaps(overlaps)
        sorted = overlaps.sort_by { |hit| [hit.t1.begin, hit.t2.begin] }
        sorted.each_with_object([]) do |hit, merged|
          last = merged.last
          if last &&
              hit.t1.begin <= last.t1.end + PARAM_TOL &&
              hit.t2.begin <= last.t2.end + PARAM_TOL
            merged[-1] = Hit.new(
              :overlap,
              last.t1.begin..[last.t1.end, hit.t1.end].max,
              last.t2.begin..[last.t2.end, hit.t2.end].max,
              last.point,
            )
          else
            merged << hit
          end
        end
      end

      def remap_hit(hit, range_a, range_b)
        if hit.kind == :overlap
          Hit.new(
            :overlap,
            remap_range(hit.t1, range_a),
            remap_range(hit.t2, range_b),
            hit.point,
          )
        else
          Hit.new(
            hit.kind,
            remap_param(hit.t1, range_a),
            remap_param(hit.t2, range_b),
            hit.point,
          )
        end
      end

      def remap_param(t, range)
        range.begin + (t * (range.end - range.begin))
      end

      def remap_range(range, outer)
        remap_param(range.begin, outer)..remap_param(range.end, outer)
      end

      def swap_hit(hit)
        if hit.kind == :overlap
          Hit.new(:overlap, hit.t2, hit.t1, hit.point)
        else
          Hit.new(hit.kind, hit.t2, hit.t1, hit.point)
        end
      end

      def quad_roots(line, quad, roots, tangent, tol)
        hits = []
        roots.each do |t|
          next unless in_range?(t)

          t = t.clamp(0.0, 1.0)
          point = quad.evaluate(t)
          u = project_param(line, point)
          next unless in_range?(u)

          hits << Hit.new(tangent ? :tangent : :crossing, u.clamp(0.0, 1.0), t, point)
        end
        hits
      end

      def project_param(segment, point)
        d = Vec.sub(segment.p1, segment.p0)
        dd = Vec.dot(d, d)
        return 0.0 if dd.zero?

        Vec.dot(Vec.sub(point, segment.p0), d) / dd
      end

      # Parameter at which a collinear quadratic curve passes through
      # point, found by solving its parametric equation along the dominant
      # axis of its chord.
      def quad_param_at(quad, point)
        axis =
          if (quad.p1[0] - quad.p0[0]).abs >= (quad.p1[1] - quad.p0[1]).abs
            0
          else
            1
          end
        a = quad.p0[axis] - (2 * quad.c[axis]) + quad.p1[axis]
        b = 2 * (quad.c[axis] - quad.p0[axis])
        d = quad.p0[axis] - point[axis]

        if a.abs <= PARAM_TOL
          return 0.0 if b.abs <= PARAM_TOL

          return (-d / b).clamp(0.0, 1.0)
        end

        disc = (b * b) - (4 * a * d)
        return (-b / (2 * a)).clamp(0.0, 1.0) if disc <= 0

        sqrt = Math.sqrt(disc)
        candidates = [(-b + sqrt) / (2 * a), (-b - sqrt) / (2 * a)]
        in_range = candidates.find { |t| t.between?(0.0, 1.0) }
        (in_range || candidates.first).clamp(0.0, 1.0)
      end

      def in_range?(t)
        t.between?(-PARAM_TOL, 1 + PARAM_TOL)
      end

      def bbox_overlap?(box_a, box_b, tol)
        box_a[0] <= box_b[2] + tol && box_b[0] <= box_a[2] + tol &&
          box_a[1] <= box_b[3] + tol && box_b[1] <= box_a[3] + tol
      end

      def bbox_extent(bbox)
        [bbox[2] - bbox[0], bbox[3] - bbox[1]].max
      end
    end
  end
end
