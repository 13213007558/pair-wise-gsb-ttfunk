# frozen_string_literal: true

require_relative 'outline_inspector/geometry'
require_relative 'outline_inspector/intersections'
require_relative 'outline_inspector/contour'

module TTFunk
  # Read-only outline inspector for TrueType (glyf) glyphs.
  #
  # It expands glyph contours into line and quadratic Bézier segments and
  # computes diagnostics directly from the curves:
  #
  # * true signed area of each contour (analytically integrated over the
  #   curve, never from the control polygon),
  # * nesting of outer contours and holes,
  # * self-intersections, intersections between contours, overlapping
  #   edges, and tangent contacts where the fill result is uncertain.
  #
  # Every issue is reported with the glyph ID, contour index, segment
  # index, and curve parameter so callers can locate the problem. The
  # inspector never modifies the font; whether and how to fix anything is
  # left to the caller.
  #
  # @example
  #   file = TTFunk::File.open('font.ttf')
  #   report = TTFunk::OutlineInspector.new(file).inspect_glyph(36)
  #   puts report
  class OutlineInspector
    # Relative geometric tolerance used for curve computations.
    GEOM_TOLERANCE = 1e-7

    # A single diagnostic finding.
    class Issue
      # Issue type: :self_intersection, :contour_intersection,
      # :overlapping_edges, :tangent_contact, :orientation_mismatch,
      # :uncertain_nesting, or :degenerate_contour.
      # @return [Symbol]
      attr_reader :type

      # Human-readable description.
      # @return [String]
      attr_reader :message

      # Where the issue is: an array of hashes with :contour, :segment,
      # and :t keys. :segment and :t are nil for contour-wide issues;
      # :t is a Range for overlapping edges.
      # @return [Array<Hash>]
      attr_reader :locations

      # Approximate (x, y) position of the issue, if punctual.
      # @return [Array(Float, Float), nil]
      attr_reader :point

      def initialize(type, message, locations, point = nil)
        @type = type
        @message = message
        @locations = locations
        @point = point
      end

      def to_s
        location = locations.map { |loc| format_location(loc) }.join(' <-> ')
        position = point ? " at (#{point[0].round(2)}, #{point[1].round(2)})" : ''
        "#{type}#{position}: #{message} [#{location}]"
      end

      private

      def format_location(loc)
        text = "contour #{loc[:contour]}"
        text += " segment #{loc[:segment]}" if loc[:segment]
        if loc[:t].is_a?(Range)
          text += format(' t=%.4f..%.4f', loc[:t].begin, loc[:t].end)
        elsif loc[:t]
          text += format(' t=%.4f', loc[:t])
        end
        text
      end
    end

    # Per-contour summary of an inspection.
    class ContourReport
      # Contour index within the glyph.
      # @return [Integer]
      attr_reader :index

      # True signed area of the contour.
      # @return [Float]
      attr_reader :signed_area

      # :clockwise, :counterclockwise, or :degenerate.
      # @return [Symbol]
      attr_reader :direction

      # Nesting depth: how many other contours contain this one.
      # @return [Integer]
      attr_reader :depth

      # :outer, :hole, or :uncertain.
      # @return [Symbol]
      attr_reader :role

      # Number of expanded curve segments.
      # @return [Integer]
      attr_reader :segment_count

      def initialize(index, signed_area, direction, depth, role, segment_count)
        @index = index
        @signed_area = signed_area
        @direction = direction
        @depth = depth
        @role = role
        @segment_count = segment_count
      end

      def to_s
        format(
          'contour %d: signed_area=%.2f (%s), depth=%d, role=%s, segments=%d',
          index, signed_area, direction, depth, role, segment_count
        )
      end
    end

    # Inspection result for one glyph.
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

      # Why the glyph could not be inspected, if unsupported.
      # @return [String, nil]
      attr_reader :unsupported_reason

      def initialize(glyph_id, contours: [], issues: [], unsupported_reason: nil)
        @glyph_id = glyph_id
        @contours = contours
        @issues = issues
        @unsupported_reason = unsupported_reason
      end

      # Was the glyph inspected?
      def supported?
        unsupported_reason.nil?
      end

      # Was the glyph inspected and found free of issues?
      def ok?
        supported? && issues.empty?
      end

      def to_s
        unless supported?
          return "glyph #{glyph_id}: not inspected (#{unsupported_reason})"
        end

        lines = ["glyph #{glyph_id}: #{contours.length} contours, #{issues.length} issues"]
        contours.each { |contour| lines << "  #{contour}" }
        issues.each { |issue| lines << "  #{issue}" }
        lines.join("\n")
      end
    end

    # @param file [TTFunk::File, nil] font to inspect glyphs of. May be nil
    #   if only #inspect_contours is used.
    def initialize(file = nil)
      @file = file
    end

    # Inspect a glyph of the font by ID. Works with simple (non-compound)
    # TrueType glyphs; blank and compound glyphs are reported as
    # unsupported.
    #
    # @param glyph_id [Integer]
    # @return [Report]
    def inspect_glyph(glyph_id)
      raise ArgumentError, 'no font provided' unless @file

      glyph = @file.glyph_outlines.for(glyph_id)
      return Report.new(glyph_id, unsupported_reason: 'blank glyph') if glyph.nil?

      if glyph.compound?
        return Report.new(glyph_id, unsupported_reason: 'compound glyph')
      end

      inspect_contours(parse_simple_glyph(glyph), glyph_id: glyph_id)
    end

    # Inspect raw contours. Each contour is an array of
    # [x, y, on_curve] points.
    #
    # @param contours [Array]
    # @param glyph_id [Integer, nil] glyph ID to record in the report
    # @return [Report]
    def inspect_contours(contours, glyph_id: nil)
      built = contours.map { |points| Contour.new(points) }
      tol = tolerance_for(built)

      issues = []
      issues.concat(self_intersections(built, tol))
      issues.concat(contour_intersections(built, tol))
      reports = analyze_nesting(built, tol, issues)
      issues.concat(orientation_issues(reports))

      Report.new(glyph_id, contours: reports, issues: issues)
    end

    private

    def tolerance_for(contours)
      scale = 1.0
      contours.each do |contour|
        box = contour.bbox
        next unless box

        scale = [scale, box[2] - box[0], box[3] - box[1]].max
      end
      scale * GEOM_TOLERANCE
    end

    def self_intersections(contours, tol)
      issues = []
      contours.each_with_index do |contour, ci|
        segments = contour.segments
        last = segments.length - 1
        segments.each_with_index do |seg_a, i|
          ((i + 1)..last).each do |j|
            seg_b = segments[j]
            forward = j == i + 1
            closing = i.zero? && j == last

            # Vertices shared by adjacent segments (a two-segment contour
            # shares both) are normal connectivity, not intersections.
            shared = []
            shared << seg_a.p1 if forward
            shared << seg_a.p0 if closing

            Intersections.between(seg_a, seg_b, tol).each do |hit|
              next if shared_vertex?(hit, shared, tol)

              issues << hit_issue(hit, [ci, i], [ci, j], true)
            end
          end
        end
      end
      dedupe_issues(issues)
    end

    def contour_intersections(contours, tol)
      issues = []
      contours.each_with_index do |contour_a, ci|
        ((ci + 1)...contours.length).each do |cj|
          contour_b = contours[cj]
          next unless bbox_overlap?(contour_a.bbox, contour_b.bbox, tol)

          contour_a.segments.each_with_index do |seg_a, i|
            contour_b.segments.each_with_index do |seg_b, j|
              Intersections.between(seg_a, seg_b, tol).each do |hit|
                issues << hit_issue(hit, [ci, i], [cj, j], false)
              end
            end
          end
        end
      end
      dedupe_issues(issues)
    end

    def hit_issue(hit, (contour_a, segment_a), (contour_b, segment_b), same_contour)
      locations = [
        { contour: contour_a, segment: segment_a, t: hit.t1 },
        { contour: contour_b, segment: segment_b, t: hit.t2 },
      ]

      case hit.kind
      when :crossing
        if endpoint?(hit.t1) && endpoint?(hit.t2)
          # Segments meet at vertices: a touch, not a crossing.
          type = :tangent_contact
          message = 'contours touch at a vertex; containment is uncertain at this point'
        else
          type = same_contour ? :self_intersection : :contour_intersection
          message =
            if same_contour
              'contour crosses itself'
            else
              'contour crosses another contour'
            end
        end
      when :tangent
        type = :tangent_contact
        message = 'edges touch tangentially; containment is uncertain at this point'
      when :overlap
        type = :overlapping_edges
        message = 'edges overlap (coincident geometry)'
      end

      Issue.new(type, message, locations, hit.point)
    end

    def endpoint?(t)
      t.is_a?(Numeric) && (t < 1e-6 || t > 1 - 1e-6)
    end

    def shared_vertex?(hit, shared, tol)
      return false if hit.kind == :overlap
      return false if shared.empty?

      shared.any? do |vertex|
        (hit.point[0] - vertex[0]).abs <= tol &&
          (hit.point[1] - vertex[1]).abs <= tol
      end
    end

    def dedupe_issues(issues)
      seen = {}
      issues.each_with_object([]) do |issue, result|
        key = [issue.type, issue.locations.map { |loc| loc[:contour] }.sort]
        key <<
          if issue.point
            issue.point.map { |coord| coord.round(2) }
          else
            issue.locations.map { |loc| loc[:t].to_s }
          end
        next if seen[key]

        seen[key] = true
        result << issue
      end
    end

    def analyze_nesting(contours, tol, issues)
      empty = contours.map { |contour| contour.segments.empty? }
      contours.each_with_index do |contour, i|
        next unless empty[i]

        issues << Issue.new(
          :degenerate_contour,
          'contour has no drawable segments',
          [{ contour: i, segment: nil, t: nil }],
        )
      end

      containment = {}
      contours.each_with_index do |inner, i|
        next if empty[i]

        contours.each_with_index do |outer, j|
          next if i == j || empty[j]

          containment[[i, j]] = containment_of(inner, outer, tol)
        end
      end

      area_tol = tol * tol
      contours.each_with_index.map do |contour, i|
        depth = 0
        uncertain = false
        contours.each_index do |j|
          next if i == j

          result = containment[[i, j]]
          if result == :uncertain
            uncertain = true
          elsif result
            depth += 1
          end
        end

        role =
          if uncertain
            issues << Issue.new(
              :uncertain_nesting,
              'nesting could not be determined; contour touches another contour',
              [{ contour: i, segment: nil, t: nil }],
            )
            :uncertain
          elsif depth.even?
            :outer
          else
            :hole
          end

        ContourReport.new(
          i,
          contour.signed_area,
          contour.direction(area_tol),
          depth,
          empty[i] ? :degenerate : role,
          contour.segments.length,
        )
      end
    end

    # Is any probe point of inner strictly inside outer? Returns true,
    # false, or :uncertain when every probe is too close to the boundary
    # to tell.
    def containment_of(inner, outer, tol)
      inner.probe_points.each do |point|
        result = point_in_contour(point, outer, tol)
        return result unless result == :uncertain
      end
      :uncertain
    end

    def point_in_contour(point, contour, tol)
      crossings = 0
      contour.segments.each do |segment|
        result = segment.ray_crossings(point, tol)
        return :uncertain if result == :uncertain

        crossings += result
      end
      crossings.odd?
    end

    # TrueType convention: outer contours run clockwise, holes
    # counterclockwise.
    def orientation_issues(reports)
      reports.filter_map do |report|
        next if report.role == :uncertain || report.direction == :degenerate

        expected = report.role == :outer ? :clockwise : :counterclockwise
        next if report.direction == expected

        Issue.new(
          :orientation_mismatch,
          "contour runs #{report.direction} but its nesting role " +            "(#{report.role}) expects #{expected}",
          [{ contour: report.index, segment: nil, t: nil }],
        )
      end
    end

    def bbox_overlap?(box_a, box_b, tol)
      return false unless box_a && box_b

      box_a[0] <= box_b[2] + tol && box_b[0] <= box_a[2] + tol &&
        box_a[1] <= box_b[3] + tol && box_b[1] <= box_a[3] + tol
    end

    # Parse point data of a simple glyph from its raw bytes.
    #
    # @return [Array] contours as [x, y, on_curve] point triples
    def parse_simple_glyph(glyph)
      io = StringIO.new(glyph.raw)
      io.read(10) # glyph header
      io.read(glyph.number_of_contours * 2) # end points of contours
      instruction_length = io.read(2).unpack1('n')
      io.read(instruction_length)

      end_points = glyph.end_points_of_contours
      point_count = end_points.empty? ? 0 : end_points.last + 1

      flags = []
      while flags.length < point_count
        flag = io.read(1).unpack1('C')
        flags << flag
        if flag.allbits?(0x08) # repeat flag
          io.read(1).unpack1('C').times { flags << flag }
        end
      end

      xs = read_coordinates(io, flags, 0x02, 0x10)
      ys = read_coordinates(io, flags, 0x04, 0x20)

      contours = []
      start = 0
      end_points.each do |end_point|
        contours << (start..end_point).map { |k| [xs[k], ys[k], flags[k].allbits?(0x01)] }
        start = end_point + 1
      end
      contours
    end

    def read_coordinates(io, flags, short_bit, same_bit)
      values = []
      current = 0
      flags.each do |flag|
        if flag.allbits?(short_bit)
          delta = io.read(1).unpack1('C')
          delta = -delta unless flag.allbits?(same_bit)
          current += delta
        elsif !flag.allbits?(same_bit)
          current += BinUtils.twos_comp_to_int(io.read(2).unpack1('n'), bit_width: 16)
        end
        values << current
      end
      values
    end
  end
end
