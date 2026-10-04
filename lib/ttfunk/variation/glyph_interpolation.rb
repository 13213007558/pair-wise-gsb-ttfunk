# frozen_string_literal: true

require_relative '../bin_utils'

module TTFunk
  module Variation
    # Applies `gvar` tuple variations to TrueType `glyf` outlines and the four
    # phantom points used to derive horizontal metrics.
    #
    # @api private
    module GlyphInterpolation
      module_function

      # Decode a simple glyph into a mutable representation.
      #
      # @return [Hash] coordinates, flags, contours, instructions
      def decode_simple_glyph(raw)
        io = StringIO.new(raw)
        number_of_contours, x_min, y_min, x_max, y_max =
          io.read(10).unpack('n*').map do |value|
            BinUtils.twos_comp_to_int(value, bit_width: 16)
          end

        end_points = io.read(number_of_contours * 2).unpack('n*')
        instruction_length = io.read(2).unpack1('n')
        instructions = io.read(instruction_length).b

        point_count = end_points.last + 1
        flags = read_flags(io, point_count)
        coordinates = read_coordinates(io, point_count, flags)

        {
          number_of_contours: number_of_contours,
          bbox: [x_min, y_min, x_max, y_max],
          end_points_of_contours: end_points,
          instructions: instructions,
          flags: flags,
          coordinates: coordinates,
        }
      end

      # Encode a decoded simple glyph using interpolated integer coordinates.
      #
      # @param glyph [Hash]
      # @return [String]
      def encode_simple_glyph(glyph)
        coordinates = glyph[:coordinates]
        flags = glyph[:flags]
        integer_coordinates = coordinates.map { |x, y| [Integer(x), Integer(y)] }
        glyph[:coordinates] = integer_coordinates
        x_min, y_min, x_max, y_max = bbox_of(integer_coordinates)

        result = [glyph[:number_of_contours], x_min, y_min, x_max, y_max]
          .map { |value| to_unsigned(value, 16) }
          .pack('n*')
        result << glyph[:end_points_of_contours].pack('n*')
        result << [glyph[:instructions].length].pack('n')
        result << glyph[:instructions]
        coordinates_data = encode_coordinates(coordinates, flags)
        result << encode_flags(flags)
        result << coordinates_data
        result
      end

      # Expand sparse tuple deltas using IUP interpolation.
      #
      # Contours and the four phantom points are each interpolated as closed
      # sequences, matching the OpenType inferred-deltas rules.
      #
      # @param deltas [Array<Array(Float, Float), nil>]
      # @param coordinates [Array<Array(Integer, Integer)>]
      # @param end_points [Array<Integer>] last point index of each contour
      # @return [Array<Array(Float, Float)>]
      def infer_deltas(deltas, coordinates, end_points)
        sections = contour_sections(end_points, deltas.length)
        result = Array.new(deltas.length)

        sections.each do |section|
          section_deltas = deltas[section]
          section_coordinates = coordinates[section]

          interpolate_contour(section_deltas, section_coordinates).each_with_index do |delta, index|
            result[section.begin + index] = delta
          end
        end

        result
      end

      # @param coordinates [Array<Array(Numeric, Numeric)>]
      # @return [Array(Integer, Integer, Integer, Integer)]
      def bbox_of(coordinates)
        xs = coordinates.map { |point| point[0] }
        ys = coordinates.map { |point| point[1] }
        [xs.min, ys.min, xs.max, ys.max]
      end

      # TrueType-style rounding to the nearest integer, with halves away from
      # zero. This matches the rasterizer behavior for applying gvar deltas.
      def round(value)
        value >= 0 ? (value + 0.5).floor : -((-value + 0.5).floor)
      end

      def read_flags(io, point_count)
        flags = []

        while flags.length < point_count
          flag = io.read(1).unpack1('C')
          count = 1

          if (flag & 0x08) != 0
            count = io.read(1).unpack1('C') + 1
            count = point_count - flags.length if flags.length + count > point_count
          end

          flags.concat(Array.new(count, flag))
          break if flags.length >= point_count
        end

        flags
      end

      def read_coordinates(io, point_count, flags)
        xs = Array.new(point_count)
        ys = Array.new(point_count)
        x = 0
        y = 0

        point_count.times do |index|
          flag = flags[index]
          x += read_coordinate(io, flag, x_bit: 0x02, sign_positive: 0x10)
          xs[index] = x
        end

        point_count.times do |index|
          flag = flags[index]
          y += read_coordinate(io, flag, x_bit: 0x04, sign_positive: 0x20)
          ys[index] = y
        end

        xs.zip(ys)
      end

      def read_coordinate(io, flag, x_bit:, sign_positive:)
        if (flag & x_bit) != 0
          value = io.read(1).unpack1('C')
          (flag & sign_positive).zero? ? -value : value
        elsif (flag & sign_positive) != 0
          0
        else
          io.read(2).unpack1('s>')
        end
      end

      def encode_flags(flags)
        encoded = +''.b
        index = 0

        while index < flags.length
          flag = flags[index] & 0xF7
          run = 1
          while index + run < flags.length &&
              (flags[index + run] & 0xF7) == flag
            run += 1
          end

          if run > 1
            encoded << [flag | 0x08, run - 1].pack('CC')
          else
            encoded << [flag].pack('C')
          end

          index += run
        end

        encoded
      end

      def encode_coordinates(coordinates, flags)
        # Rewrite coordinate flags from the actual integer deltas while
        # preserving semantic flags such as the on-curve bit.
        previous_x = 0
        previous_y = 0
        xs = []
        ys = []

        coordinates.each_with_index do |(x, y), index|
          dx = Integer(x) - previous_x
          dy = Integer(y) - previous_y
          xs << dx
          ys << dy
          previous_x = Integer(x)
          previous_y = Integer(y)
          flags[index] = encode_coordinate_flags(flags[index] & 0xF7, dx, dy)
        end

        encoded = +''.b
        xs.each { |value| encoded << encode_coordinate_value(value) }
        ys.each { |value| encoded << encode_coordinate_value(value) }
        encoded
      end

      def encode_coordinate_flags(flag, dx, dy)
        flag &= ~(0x02 | 0x10 | 0x40 | 0x04 | 0x20 | 0x80)
        flag |= coordinate_flag_bits(dx, short: 0x02, same_sign: 0x10)
        flag |= coordinate_flag_bits(dy, short: 0x04, same_sign: 0x20)
        flag
      end

      def coordinate_flag_bits(value, short:, same_sign:)
        return same_sign if value.zero?
        return short | same_sign if value.positive? && value.abs <= 255
        return short if value.negative? && value.abs <= 255

        0
      end

      def encode_coordinate_value(value)
        return +''.b if value.zero?

        if value.abs <= 255
          [value.abs].pack('C')
        else
          [to_unsigned(value, 16)].pack('n')
        end
      end

      def contour_sections(end_points, point_count)
        sections = []
        start = 0

        end_points.each do |end_point|
          sections << (start..end_point)
          start = end_point + 1
        end

        # Each phantom point forms its own degenerate contour for IUP purposes.
        start.upto(point_count - 1) { |index| sections << (index..index) }
        sections
      end

      def interpolate_contour(deltas, coordinates)
        explicit = deltas.each_index.select { |index| deltas[index] }

        return Array.new(deltas.length) { [0.0, 0.0] } if explicit.empty?
        if explicit.length == deltas.length
          return deltas.map { |delta| delta || [0.0, 0.0] }
        end

        result = Array.new(deltas.length, [0.0, 0.0])

        first = explicit.first
        last = explicit.last

        if first.positive?
          fill_gap(result, deltas, coordinates, 0...first, last, first)
        end

        explicit.each_cons(2) do |left, right|
          next unless right > left + 1

          fill_gap(result, deltas, coordinates, (left + 1)...right, left, right)
        end

        if last < deltas.length - 1
          fill_gap(result, deltas, coordinates, (last + 1)...deltas.length, last, first)
        end

        explicit.each { |index| result[index] = deltas[index] }
        result
      end

      def fill_gap(result, deltas, coordinates, range, left_index, right_index)
        range.each do |index|
          result[index] = [
            interpolate_axis(index, 0, deltas, coordinates, left_index, right_index),
            interpolate_axis(index, 1, deltas, coordinates, left_index, right_index),
          ]
        end
      end

      def interpolate_axis(index, axis, deltas, coordinates, left_index, right_index)
        x1 = coordinates[left_index][axis].to_f
        x2 = coordinates[right_index][axis].to_f
        d1 = deltas[left_index][axis].to_f
        d2 = deltas[right_index][axis].to_f
        x = coordinates[index][axis].to_f

        return d1 if x1 == x2 && d1 == d2
        return 0.0 if x1 == x2

        if x1 > x2
          x1, x2 = x2, x1
          d1, d2 = d2, d1
        end

        return d1 if x <= x1
        return d2 if x >= x2

        d1 + ((x - x1) * (d2 - d1) / (x2 - x1))
      end

      def to_unsigned(value, bits)
        value & ((1 << bits) - 1)
      end
    end
  end
end
