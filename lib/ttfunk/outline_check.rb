# frozen_string_literal: true

module TTFunk
  # Read-only outline diagnostics for TrueType (glyf) glyph outlines.
  #
  # Everything here is non-destructive: glyph data is only ever read, never
  # modified. TrueType quadratic outlines are expanded into line and curve
  # segments, the true signed area of every contour is computed analytically
  # from the curves themselves (the control-point polygon is never used as a
  # substitute, because its orientation can differ from the curve's),
  # outer/hole nesting is derived from even-odd containment of on-curve
  # sample points, and geometric defects are reported with glyph, contour,
  # and curve parameter positions. Whether and how to fix anything is left
  # to the caller.
  module OutlineCheck
    # A single diagnostic finding.
    #
    # * +type+ — one of :self_intersection, :contour_intersection, :overlap,
    #   :tangency, :unexpected_orientation.
    # * +glyph_id+ — glyph ID or nil when unknown.
    # * +contour_indexes+ — indexes of the contours involved.
    # * +segments+ — [contour_index, segment_index] pairs involved.
    # * +parameters+ — curve parameters (t in [0, 1]) parallel to +segments+;
    #   empty for :overlap findings, whose parameter ranges are given in the
    #   message instead.
    # * +point+ — approximate [x, y] location of the finding.
    # * +message+ — human-readable summary.
    Issue = Struct.new(
      :type, :glyph_id, :contour_indexes, :segments, :parameters,
      :point, :message,
      keyword_init: true
    )

    # Per-contour diagnostic summary.
    #
    # * +index+ — contour index within the glyph.
    # * +signed_area+ — true signed area of the expanded curve (positive is
    #   counter-clockwise).
    # * +orientation+ — :counter_clockwise, :clockwise, or :degenerate.
    # * +role+ — :outer, :hole, or :uncertain (when the contour touches or
    #   crosses another contour and nesting cannot be decided reliably).
    # * +depth+ — number of other contours containing this one.
    ContourReport = Struct.new(
      :index, :signed_area, :orientation, :role, :depth,
      keyword_init: true
    )

    # Result of checking one glyph.
    class Report
      # Glyph ID.
      # @return [Integer, nil]
      attr_reader :glyph_id

      # Per-contour summaries.
      # @return [Array<ContourReport>]
      attr_reader :contours

      # Diagnostic findings.
      # @return [Array<Issue>]
      attr_reader :issues

      # Informational notes, e.g. :compound_glyph_not_expanded.
      # @return [Array<Symbol>]
      attr_reader :notes

      def initialize(glyph_id:, contours:, issues:, notes: [])
        @glyph_id = glyph_id
        @contours = contours
        @issues = issues
        @notes = notes
      end

      # Did anything in this glyph get flagged?
      # @return [Boolean]
      def problematic?
        !issues.empty?
      end
    end

    # A point of a TrueType contour.
    Point = Struct.new(:x, :y, :on_curve) do
      def to_a
        [x, y]
      end
    end

    # A line or quadratic Bezier segment of an expanded contour.
    class Segment
      # Start point as [x, y].
      attr_reader :p0

      # Quadratic control point as [x, y], or nil for a straight line.
      attr_reader :control

      # End point as [x, y].
      attr_reader :p1

      def initialize(p0, control, p1)
        @p0 = p0
        @control = control
        @p1 = p1
      end

      # Is this a straight line segment?
      def line?
        control.nil?
      end

      # Point on the curve at parameter t in [0, 1].
      def point_at(t)
        if line?
          [
            p0[0] + (t * (p1[0] - p0[0])),
            p0[1] + (t * (p1[1] - p0[1])),
          ]
        else
          mt = 1 - t
          [
            (mt * mt * p0[0]) + (2 * mt * t * control[0]) + (t * t * p1[0]),
            (mt * mt * p0[1]) + (2 * mt * t * control[1]) + (t * t * p1[1]),
          ]
        end
      end

      # Tangent vector at parameter t.
      def tangent_at(t)
        if line?
          [p1[0] - p0[0], p1[1] - p0[1]]
        else
          [
            (2 * (1 - t) * (control[0] - p0[0])) +
              (2 * t * (p1[0] - control[0])),
            (2 * (1 - t) * (control[1] - p0[1])) +
              (2 * t * (p1[1] - control[1])),
          ]
        end
      end

      # Exact signed area swept by this segment together with the chord
      # closing it (its contribution to the contour's signed area). Positive
      # values mean counter-clockwise travel. Computed analytically from the
      # curve, never from the control polygon.
      def signed_area
        if line?
          Geometry.cross(p0, p1) / 2.0
        else
          (Geometry.cross(p0, control) / 3.0) +
            (Geometry.cross(p0, p1) / 6.0) +
            (Geometry.cross(control, p1) / 3.0)
        end
      end

      # Axis-aligned bounding box [xmin, ymin, xmax, ymax]. For curves this
      # is the (conservative) control-point bounding box.
      def bbox
        points = line? ? [p0, p1] : [p0, control, p1]
        xs = points.map(&:first)
        ys = points.map(&:last)
        [xs.min, ys.min, xs.max, ys.max]
      end

      # Split the segment at t = 0.5 (de Casteljau).
      def subdivide
        if line?
          mid = point_at(0.5)
          [Segment.new(p0, nil, mid), Segment.new(mid, nil, p1)]
        else
          a = Geometry.midpoint(p0, control)
          b = Geometry.midpoint(control, p1)
          m = Geometry.midpoint(a, b)
          [Segment.new(p0, a, m), Segment.new(m, b, p1)]
        end
      end

      # Is the curve within +tol+ of its chord?
      def flat?(tol)
        return true if line?

        if Geometry.distance(p0, p1).zero?
          Geometry.distance(p0, control) <= tol
        else
          Geometry.point_line_distance(control, p0, p1) <= tol
        end
      end
    end

    # Small vector helpers on [x, y] pairs.
    module Geometry
      module_function

      def cross(a, b)
        (a[0] * b[1]) - (a[1] * b[0])
      end

      def sub(a, b)
        [a[0] - b[0], a[1] - b[1]]
      end

      def midpoint(a, b)
        [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
      end

      def distance(a, b)
        Math.hypot(a[0] - b[0], a[1] - b[1])
      end

      def point_line_distance(p, a, b)
        cross(sub(b, a), sub(p, a)).abs / distance(a, b)
      end
    end

    # Tolerance for curve flattening during intersection search, font units.
    FLATNESS_TOLERANCE = 0.01
    # Maximum subdivision depth for curve intersection search.
    MAX_SUBDIVISION_DEPTH = 40
    # Tolerance for merging duplicate intersection hits (curve parameter).
    HIT_MERGE_TOLERANCE = 1e-3
    # Relative tolerance for treating two tangents as parallel.
    TANGENT_TOLERANCE = 1e-3
    # Zero tolerance for exact geometric predicates.
    EPSILON = 1e-9

    class << self
      # Check a parsed glyph (TTFunk::Table::Glyf::Simple or Compound).
      #
      # @return [Report]
      def check_glyph(glyph)
        if glyph.compound?
          return Report.new(
            glyph_id: glyph.id,
            contours: [],
            issues: [],
            notes: [:compound_glyph_not_expanded],
          )
        end

        build_report(glyph.id, expand_all(parse_points(glyph)))
      end

      # Check raw contours directly. +contours+ is an array of contours,
      # each an array of [x, y, on_curve] triples in font units.
      #
      # @return [Report]
      def check_contours(contours, glyph_id: nil)
        point_contours = contours.map { |contour|
          contour.map { |x, y, on_curve| Point.new(x, y, on_curve) }
        }
        build_report(glyph_id, expand_all(point_contours))
      end

      # Check glyphs of a font file. Returns one Report per glyph that has
      # an outline (blank glyphs are skipped). Only TrueType (glyf) fonts
      # are supported; returns an empty array for CFF-based fonts.
      #
      # @param file [TTFunk::File]
      # @param glyph_ids [Enumerable<Integer>, nil] glyph IDs to check;
      #   defaults to all glyphs in the font.
      # @return [Array<Report>]
      def check_file(file, glyph_ids = nil)
        return [] unless file.directory.tables.include?('glyf')

        glyph_ids ||= (0...file.maximum_profile.num_glyphs)
        glyph_ids.filter_map { |glyph_id|
          glyph = file.find_glyph(glyph_id)
          check_glyph(glyph) if glyph
        }
      end

      private

      # --- glyph parsing --------------------------------------------------

      def parse_points(glyph)
        io = StringIO.new(glyph.raw)
        io.pos = 10 + (glyph.number_of_contours * 2) + 2 +
          glyph.instruction_length
        point_count = glyph.end_points_of_contours.last + 1

        flags = []
        while flags.length < point_count
          flag = io.read(1).unpack1('C')
          flags << flag
          if flag.anybits?(0x08) # REPEAT
            io.read(1).unpack1('C').times { flags << flag }
          end
        end

        xs = decode_coordinates(io, flags, 0x02, 0x10)
        ys = decode_coordinates(io, flags, 0x04, 0x20)

        contours = []
        start = 0
        glyph.end_points_of_contours.each do |end_point|
          contours << (start..end_point).map { |i|
            Point.new(xs[i], ys[i], flags[i].anybits?(0x01))
          }
          start = end_point + 1
        end
        contours
      end

      def decode_coordinates(io, flags, short_bit, same_bit)
        current = 0
        flags.map { |flag|
          delta =
            if flag.anybits?(short_bit)
              magnitude = io.read(1).unpack1('C')
              flag.anybits?(same_bit) ? magnitude : -magnitude
            elsif flag.anybits?(same_bit)
              0
            else
              BinUtils.twos_comp_to_int(io.read(2).unpack1('n'), bit_width: 16)
            end
          current += delta
        }
      end

      # --- contour expansion -----------------------------------------------

      def expand_all(point_contours)
        point_contours.map { |points| expand_contour(points) }
      end

      # Expand a TrueType point contour into segments, inserting the implied
      # on-curve points between consecutive off-curve points.
      def expand_contour(points)
        return [] if points.empty?

        count = points.length
        first = points.first
        last = points.last
        start_point, start_index =
          if first.on_curve
            [first.to_a, 0]
          elsif last.on_curve
            [last.to_a, count - 1]
          else
            [Geometry.midpoint(first.to_a, last.to_a), count - 1]
          end

        segments = []
        current = start_point
        consumed = 0
        index = start_index
        while consumed < count
          index = (index + 1) % count
          point = points[index]
          consumed += 1
          if point.on_curve
            segments << Segment.new(current, nil, point.to_a)
            current = point.to_a
          else
            nxt = points[(index + 1) % count]
            if nxt.on_curve
              segments << Segment.new(current, point.to_a, nxt.to_a)
              current = nxt.to_a
              consumed += 1
              index = (index + 1) % count
            else
              mid = Geometry.midpoint(point.to_a, nxt.to_a)
              segments << Segment.new(current, point.to_a, mid)
              current = mid
            end
          end
        end
        segments
      end

      # --- report assembly ---------------------------------------------------

      def build_report(glyph_id, contour_segments)
        findings = find_intersections(contour_segments)
        issues = findings.map { |finding| to_issue(glyph_id, finding) }
        uncertain = uncertain_contours(findings)
        containers = containment(contour_segments)

        contours = contour_segments.each_with_index.map { |segments, index|
          area = segments.sum(&:signed_area)
          orientation = orientation_of(area)
          role =
            if uncertain.include?(index)
              :uncertain
            elsif containers[index].length.even?
              :outer
            else
              :hole
            end

          orientation_issue =
            check_orientation(glyph_id, index, role, orientation, area)
          issues << orientation_issue if orientation_issue

          ContourReport.new(
            index: index,
            signed_area: area,
            orientation: orientation,
            role: role,
            depth: containers[index].length,
          )
        }

        Report.new(glyph_id: glyph_id, contours: contours, issues: issues)
      end

      def orientation_of(area)
        if area.abs <= EPSILON
          :degenerate
        elsif area.positive?
          :counter_clockwise
        else
          :clockwise
        end
      end

      # TrueType fill convention: outer contours run clockwise, holes
      # counter-clockwise. Report (but don't fix) deviations.
      def check_orientation(glyph_id, index, role, orientation, area)
        return unless %i[outer hole].include?(role)
        return if orientation == :degenerate

        expected = role == :outer ? :clockwise : :counter_clockwise
        return if orientation == expected

        Issue.new(
          type: :unexpected_orientation,
          glyph_id: glyph_id,
          contour_indexes: [index],
          segments: [],
          parameters: [],
          point: nil,
          message: format(
            'glyph %<g>s contour %<c>d: %<r>s contour runs %<o>s ' +
              '(signed area %<a>.2f)',
            g: glyph_id || '?', c: index, r: role, o: orientation, a: area,
          ),
        )
      end

      # --- intersection search ---------------------------------------------

      # Returns a list of finding hashes:
      #   { kind:, ci:, ai:, cj:, bj:, t:, u:, t_range:, u_range:, point: }
      # kind is one of :crossing, :tangency, :overlap.
      def find_intersections(contour_segments)
        findings = []
        indexed = contour_segments.flat_map.with_index { |segments, ci|
          segments.map.with_index { |segment, si| [ci, si, segment] }
        }

        indexed.combination(2) do |(ci, ai, seg_a), (cj, bj, seg_b)|
          adjacent =
            ci == cj &&
            (bj == ai + 1 || (ai.zero? && bj == contour_segments[ci].length - 1))
          findings.concat(
            segment_findings(seg_a, seg_b, adjacent).map { |hit|
              hit.merge(ci: ci, ai: ai, cj: cj, bj: bj)
            },
          )
        end
        findings
      end

      def segment_findings(seg_a, seg_b, adjacent)
        if seg_a.line? && seg_b.line?
          return line_line_findings(seg_a, seg_b, adjacent)
        end

        if coincident_quads?(seg_a, seg_b)
          return [{
            kind: :overlap,
            t_range: [0.0, 1.0],
            u_range: [0.0, 1.0],
            point: seg_a.point_at(0.5),
          }]
        end

        curve_hits(seg_a, seg_b).filter_map { |hit|
          t = hit[:t].clamp(0.0, 1.0)
          u = hit[:u].clamp(0.0, 1.0)
          point = seg_a.point_at(t)
          next if adjacent && shared_endpoint?(seg_a, seg_b, point)

          kind = tangent_hit?(seg_a, seg_b, t, u) ? :tangency : :crossing
          { kind: kind, t: t, u: u, point: point }
        }
      end

      # Exact intersection of two straight segments.
      def line_line_findings(seg_a, seg_b, adjacent)
        r = Geometry.sub(seg_a.p1, seg_a.p0)
        s = Geometry.sub(seg_b.p1, seg_b.p0)
        r_len = Math.hypot(*r)
        s_len = Math.hypot(*s)
        return [] if r_len <= EPSILON || s_len <= EPSILON

        denom = Geometry.cross(r, s)
        qp = Geometry.sub(seg_b.p0, seg_a.p0)

        if denom.abs > EPSILON * r_len * s_len
          t = Geometry.cross(qp, s).fdiv(denom)
          u = Geometry.cross(qp, r).fdiv(denom)
          return [] unless t.between?(-EPSILON, 1 + EPSILON)
          return [] unless u.between?(-EPSILON, 1 + EPSILON)

          t = t.clamp(0.0, 1.0)
          u = u.clamp(0.0, 1.0)
          point = seg_a.point_at(t)
          return [] if adjacent && shared_endpoint?(seg_a, seg_b, point)

          kind = tangent_hit?(seg_a, seg_b, t, u) ? :tangency : :crossing
          return [{ kind: kind, t: t, u: u, point: point }]
        end

        # Parallel: only collinear segments are interesting (overlap).
        return [] if Geometry.cross(qp, r).abs > EPSILON * r_len * s_len

        axis = r[0].abs >= r[1].abs ? 0 : 1
        span = seg_a.p1[axis] - seg_a.p0[axis]
        return [] if span.abs <= EPSILON

        tb0 = (seg_b.p0[axis] - seg_a.p0[axis]).fdiv(span)
        tb1 = (seg_b.p1[axis] - seg_a.p0[axis]).fdiv(span)
        lo = [0.0, [tb0, tb1].min].max
        hi = [1.0, [tb0, tb1].max].min
        return [] unless hi - lo > EPSILON

        u_span = seg_b.p1[axis] - seg_b.p0[axis]
        u_range =
          if u_span.abs <= EPSILON
            [0.0, 1.0]
          else
            ua = (seg_a.point_at(lo)[axis] - seg_b.p0[axis]).fdiv(u_span)
            ub = (seg_a.point_at(hi)[axis] - seg_b.p0[axis]).fdiv(u_span)
            [ua, ub].sort
          end

        [{
          kind: :overlap,
          t_range: [lo, hi],
          u_range: u_range,
          point: seg_a.point_at((lo + hi) / 2.0),
        }]
      end

      # Do two curves share (nearly) identical control points, i.e. trace
      # the same geometric curve?
      def coincident_quads?(seg_a, seg_b)
        return false if seg_a.line? || seg_b.line?

        close = ->(p, q) { Geometry.distance(p, q) <= 1e-6 }
        (close.call(seg_a.p0, seg_b.p0) &&
          close.call(seg_a.control, seg_b.control) &&
          close.call(seg_a.p1, seg_b.p1)) ||
          (close.call(seg_a.p0, seg_b.p1) &&
            close.call(seg_a.control, seg_b.control) &&
            close.call(seg_a.p1, seg_b.p0))
      end

      # Intersect two segments (at least one a curve) by recursive
      # subdivision of the actual curves. Returns [{t:, u:}].
      def curve_hits(seg_a, seg_b)
        raw = []
        subdivide_intersect(seg_a, seg_b, 0.0, 1.0, 0.0, 1.0, 0, raw)
        merge_hits(raw)
      end

      def subdivide_intersect(seg_a, seg_b, ta0, ta1, tb0, tb1, depth, out)
        return unless bbox_overlap?(seg_a.bbox, seg_b.bbox)

        if seg_a.flat?(FLATNESS_TOLERANCE) && seg_b.flat?(FLATNESS_TOLERANCE)
          chord_a = Segment.new(seg_a.p0, nil, seg_a.p1)
          chord_b = Segment.new(seg_b.p0, nil, seg_b.p1)
          line_line_findings(chord_a, chord_b, false).each { |hit|
            if hit[:t_range]
              t = hit[:t_range].sum / 2.0
              u = hit[:u_range].sum / 2.0
            else
              t = hit[:t]
              u = hit[:u]
            end
            out << {
              t: ta0 + (t * (ta1 - ta0)),
              u: tb0 + (u * (tb1 - tb0)),
            }
          }
          return
        end

        if depth >= MAX_SUBDIVISION_DEPTH
          out << { t: (ta0 + ta1) / 2.0, u: (tb0 + tb1) / 2.0 }
          return
        end

        if bbox_size(seg_a.bbox) >= bbox_size(seg_b.bbox)
          left, right = seg_a.subdivide
          mid = (ta0 + ta1) / 2.0
          subdivide_intersect(left, seg_b, ta0, mid, tb0, tb1, depth + 1, out)
          subdivide_intersect(right, seg_b, mid, ta1, tb0, tb1, depth + 1, out)
        else
          top, bottom = seg_b.subdivide
          mid = (tb0 + tb1) / 2.0
          subdivide_intersect(seg_a, top, ta0, ta1, tb0, mid, depth + 1, out)
          subdivide_intersect(seg_a, bottom, ta0, ta1, mid, tb1, depth + 1, out)
        end
      end

      def merge_hits(raw)
        raw.sort_by { |hit| [hit[:t], hit[:u]] }.each_with_object([]) { |hit, merged|
          last = merged.last
          if last &&
              (hit[:t] - last[:t]).abs <= HIT_MERGE_TOLERANCE &&
              (hit[:u] - last[:u]).abs <= HIT_MERGE_TOLERANCE
            last[:t] = (last[:t] + hit[:t]) / 2.0
            last[:u] = (last[:u] + hit[:u]) / 2.0
          else
            merged << hit.dup
          end
        }
      end

      def bbox_overlap?(box_a, box_b)
        box_a[0] <= box_b[2] + EPSILON && box_b[0] <= box_a[2] + EPSILON &&
          box_a[1] <= box_b[3] + EPSILON && box_b[1] <= box_a[3] + EPSILON
      end

      def bbox_size(box)
        Math.hypot(box[2] - box[0], box[3] - box[1])
      end

      # Are the tangents at the intersection (nearly) parallel? Then the
      # contact is a tangency and the fill behaviour there is uncertain.
      def tangent_hit?(seg_a, seg_b, t, u)
        tangent_a = seg_a.tangent_at(t)
        tangent_b = seg_b.tangent_at(u)
        magnitude = Math.hypot(*tangent_a) * Math.hypot(*tangent_b)
        return true if magnitude <= EPSILON

        Geometry.cross(tangent_a, tangent_b).abs <= TANGENT_TOLERANCE * magnitude
      end

      # Is +point+ (within tolerance) an endpoint shared by both segments?
      def shared_endpoint?(seg_a, seg_b, point)
        endpoints_a = [seg_a.p0, seg_a.p1]
        endpoints_b = [seg_b.p0, seg_b.p1]
        endpoints_a.any? { |pa|
          endpoints_b.any? { |pb| Geometry.distance(pa, pb) <= 1e-6 } &&
            Geometry.distance(pa, point) <= 1e-6
        }
      end

      # Contours whose nesting cannot be decided reliably because they
      # touch or cross another contour.
      def uncertain_contours(findings)
        findings.each_with_object([]) { |finding, uncertain|
          cross_contour = finding[:ci] != finding[:cj]
          next unless finding[:kind] == :tangency || cross_contour

          uncertain << finding[:ci] << finding[:cj]
        }.uniq
      end

      # --- nesting ---------------------------------------------------------

      # containers[i] = indexes of contours containing contour i, decided
      # by even-odd containment of an on-curve sample point of contour i.
      def containment(contour_segments)
        samples = contour_segments.map { |segments|
          segments.empty? ? nil : segments.first.point_at(0.5)
        }
        contour_segments.each_with_index.map { |_, i|
          next [] if samples[i].nil?

          contour_segments.each_with_index.filter_map { |segments, j|
            next if i == j || segments.empty?

            j if point_inside?(samples[i], segments)
          }
        }
      end

      def point_inside?(point, segments)
        px, py = point
        crossings = segments.sum { |segment| ray_crossings(segment, px, py) }
        crossings.odd?
      end

      # Crossings of the +x ray from (px, py) with the segment, counted
      # analytically. Curve/ray tangencies (double roots) count twice and
      # therefore do not flip parity.
      def ray_crossings(segment, px, py)
        if segment.line?
          y0 = segment.p0[1]
          y1 = segment.p1[1]
          return 0 if (y0 > py) == (y1 > py)

          x_int = segment.p0[0] +
            ((py - y0) * (segment.p1[0] - segment.p0[0]) / (y1 - y0))
          x_int > px ? 1 : 0
        else
          y0 = segment.p0[1]
          yc = segment.control[1]
          y1 = segment.p1[1]
          roots = quadratic_roots(
            y0 - (2 * yc) + y1,
            2 * (yc - y0),
            y0 - py,
          )
          roots.count { |t|
            t > EPSILON && t <= 1 + EPSILON &&
              segment.point_at(t.clamp(0.0, 1.0))[0] > px
          }
        end
      end

      def quadratic_roots(a, b, c)
        if a.abs <= EPSILON
          return [] if b.abs <= EPSILON

          return [-c / b]
        end

        discriminant = (b * b) - (4 * a * c)
        return [] if discriminant.negative?

        root = Math.sqrt(discriminant)
        [(-b - root) / (2 * a), (-b + root) / (2 * a)]
      end

      # --- findings to issues ----------------------------------------------

      def to_issue(glyph_id, finding)
        type =
          case finding[:kind]
          when :overlap then :overlap
          when :tangency then :tangency
          else
            finding[:ci] == finding[:cj] ? :self_intersection : :contour_intersection
          end

        Issue.new(
          type: type,
          glyph_id: glyph_id,
          contour_indexes: [finding[:ci], finding[:cj]].uniq,
          segments: [[finding[:ci], finding[:ai]], [finding[:cj], finding[:bj]]],
          parameters: [finding[:t], finding[:u]].compact,
          point: finding[:point],
          message: issue_message(glyph_id, type, finding),
        )
      end

      def issue_message(glyph_id, type, finding)
        glyph = glyph_id || '?'
        where =
          if finding[:point]
            format(' near (%.2f, %.2f)', finding[:point][0], finding[:point][1])
          else
            ''
          end
        position =
          if finding[:t_range]
            format(
              'contour %<c1>d segment %<s1>d (t in %<t1>.4f..%<t2>.4f) vs ' +
                'contour %<c2>d segment %<s2>d (t in %<u1>.4f..%<u2>.4f)',
              c1: finding[:ci], s1: finding[:ai],
              t1: finding[:t_range][0], t2: finding[:t_range][1],
              c2: finding[:cj], s2: finding[:bj],
              u1: finding[:u_range][0], u2: finding[:u_range][1],
            )
          else
            format(
              'contour %<c1>d segment %<s1>d (t=%<t1>.4f) vs ' +
                'contour %<c2>d segment %<s2>d (t=%<t2>.4f)',
              c1: finding[:ci], s1: finding[:ai], t1: finding[:t],
              c2: finding[:cj], s2: finding[:bj], t2: finding[:u],
            )
          end

        case type
        when :self_intersection
          "glyph #{glyph}: self-intersection of #{position}#{where}"
        when :contour_intersection
          "glyph #{glyph}: contours cross at #{position}#{where}"
        when :overlap
          "glyph #{glyph}: overlapping edges at #{position}#{where}"
        when :tangency
          "glyph #{glyph}: tangent contact (fill uncertain) at " +
            "#{position}#{where}"
        end
      end
    end
  end
end
