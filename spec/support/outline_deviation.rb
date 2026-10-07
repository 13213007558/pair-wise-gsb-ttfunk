# frozen_string_literal: true

# Helpers for measuring the geometric deviation between CFF (cubic Bezier)
# outlines and converted TrueType (quadratic) contours in specs.
module OutlineDeviation
  # Evaluate a cubic Bezier at t.
  def cubic_bezier_at(p0, p1, p2, p3, t)
    mt = 1 - t
    [
      (mt**3 * p0[0]) + (3 * mt * mt * t * p1[0]) + (3 * mt * t * t * p2[0]) + (t**3 * p3[0]),
      (mt**3 * p0[1]) + (3 * mt * mt * t * p1[1]) + (3 * mt * t * t * p2[1]) + (t**3 * p3[1]),
    ]
  end

  # Evaluate a quadratic Bezier at t.
  def quadratic_bezier_at(p0, p1, p2, t)
    mt = 1 - t
    [
      (mt * mt * p0[0]) + (2 * mt * t * p1[0]) + (t * t * p2[0]),
      (mt * mt * p0[1]) + (2 * mt * t * p1[1]) + (t * t * p2[1]),
    ]
  end

  # Sample a CFF path into polylines, one per contour.
  #
  # @param path [TTFunk::Table::Cff::Path]
  # @param segments [Integer] samples per drawing command
  # @return [Array<Array<Array(Float, Float)>>]
  def sample_cff_path(path, segments = 50)
    polylines = []
    polyline = []
    current = nil
    start = nil

    path.commands.each do |command|
      case command[0]
      when :move
        polylines << polyline if polyline.length > 1
        polyline = []
        current = [command[1].to_f, command[2].to_f]
        start = current
        polyline << current
      when :line
        to = [command[1].to_f, command[2].to_f]
        polyline.concat(sample_segment(current, to, segments))
        current = to
      when :curve
        p1 = [command[1].to_f, command[2].to_f]
        p2 = [command[3].to_f, command[4].to_f]
        p3 = [command[5].to_f, command[6].to_f]
        (1..segments).each do |i|
          polyline << cubic_bezier_at(current, p1, p2, p3, i.to_f / segments)
        end
        current = p3
      when :close
        if current && start && current != start
          polyline.concat(sample_segment(current, start, segments))
        end
        polylines << polyline if polyline.length > 1
        polyline = []
        current = nil
        start = nil
      end
    end
    polylines << polyline if polyline.length > 1

    polylines
  end

  # Sample converted quadratic contours into polylines, one per contour.
  #
  # @param contours [Array<Array<Array(Integer, Integer, Boolean)>>] contours
  #   as produced by TTFunk::CffToTtf::PathConverter
  # @param segments [Integer] samples per quadratic segment
  # @return [Array<Array<Array(Float, Float)>>]
  def sample_quadratic_contours(contours, segments = 50)
    contours.map { |contour| sample_quadratic_contour(contour, segments) }
  end

  # Maximum deviation between two sampled outlines, measured in both
  # directions as the distance from sample points to the other outline's
  # polylines.
  #
  # @param from [Array] polylines
  # @param to [Array] polylines
  # @return [Float]
  def outline_deviation(from, to)
    [
      max_point_deviation(from, to),
      max_point_deviation(to, from),
    ].max
  end

  # Decode points of an encoded simple glyph (as read from a glyf table).
  #
  # @param raw [String] binary simple glyph data
  # @return [Array<Array<Array(Integer, Integer, Boolean)>>] contours of
  #   (x, y, on_curve) points
  def decode_simple_glyph_points(raw)
    io = StringIO.new(raw)
    number_of_contours = io.read(2).unpack1('s>')
    io.read(8) # bbox
    end_points = io.read(number_of_contours * 2).unpack('n*')
    instruction_length = io.read(2).unpack1('n')
    io.read(instruction_length)

    point_count = end_points.last + 1
    flags = []
    while flags.length < point_count
      flag = io.readbyte
      flags << flag
      if (flag & 0x08).positive? # repeat flag
        io.readbyte.times { flags << flag }
      end
    end

    xs = decode_glyph_coordinates(io, flags, 0x02, 0x10)
    ys = decode_glyph_coordinates(io, flags, 0x04, 0x20)

    points = xs.each_with_index.map { |x, i|
      [x, ys[i], (flags[i] & 0x01).positive?]
    }

    contours = []
    first = 0
    end_points.each do |end_point|
      contours << points[first..end_point]
      first = end_point + 1
    end
    contours
  end

  private

  def sample_segment(from, to, segments)
    (1..segments).map { |i|
      t = i.to_f / segments
      [from[0] + ((to[0] - from[0]) * t), from[1] + ((to[1] - from[1]) * t)]
    }
  end

  def sample_quadratic_contour(contour, segments)
    points = expand_implied_points(contour)
    points << points.first

    polyline = [points.first]
    current = points.first
    index = 1
    while index < points.length
      if points[index][2]
        to = points[index]
        polyline.concat(sample_segment(current, to, segments))
        current = to
        index += 1
      else
        control = points[index]
        to = points[index + 1]
        (1..segments).each do |i|
          polyline << quadratic_bezier_at(current, control, to, i.to_f / segments)
        end
        current = to
        index += 2
      end
    end
    polyline
  end

  # Insert implied on-curve points between consecutive off-curve points and
  # rotate the contour so it starts with an on-curve point.
  def expand_implied_points(contour)
    expanded = []
    contour.each_with_index do |point, index|
      expanded << point
      following = contour[(index + 1) % contour.length]
      if !point[2] && !following[2]
        expanded << [(point[0] + following[0]) / 2.0, (point[1] + following[1]) / 2.0, true]
      end
    end

    first_on_curve = expanded.index { |point| point[2] }
    expanded.rotate(first_on_curve)
  end

  def max_point_deviation(from, to)
    from.flat_map { |polyline|
      polyline.map { |point|
        to.map { |other| point_to_polyline_distance(point, other) }.min
      }
    }.max
  end

  def point_to_polyline_distance(point, polyline)
    polyline.each_cons(2).map { |a, b|
      point_to_segment_distance(point, a, b)
    }.min
  end

  def point_to_segment_distance(point, a, b)
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    length_squared = (dx * dx) + (dy * dy)
    return Math.hypot(point[0] - a[0], point[1] - a[1]) if length_squared.zero?

    t = (((point[0] - a[0]) * dx) + ((point[1] - a[1]) * dy)) / length_squared
    t = 0.0 if t.negative?
    t = 1.0 if t > 1
    Math.hypot(point[0] - a[0] - (t * dx), point[1] - a[1] - (t * dy))
  end

  def decode_glyph_coordinates(io, flags, short_bit, same_or_positive_bit)
    coordinates = []
    previous = 0
    flags.each do |flag|
      delta =
        if (flag & short_bit).positive?
          value = io.readbyte
          (flag & same_or_positive_bit).positive? ? value : -value
        elsif (flag & same_or_positive_bit).positive?
          0
        else
          io.read(2).unpack1('s>')
        end
      previous += delta
      coordinates << previous
    end
    coordinates
  end
end
