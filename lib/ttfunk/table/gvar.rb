# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Glyph Variations (`gvar`) table.
    class Gvar < Table
      TupleVariation = Struct.new(
        :peak, :intermediate_start, :intermediate_end, :deltas,
        keyword_init: true
      )

      EMBEDDED_PEAK_TUPLE = 0x8000
      INTERMEDIATE_REGION = 0x4000
      PRIVATE_POINT_NUMBERS = 0x2000
      TUPLES_SHARE_POINT_NUMBERS = 0x8000
      TUPLE_COUNT_MASK = 0x0fff
      LONG_OFFSETS = 0x0001

      def for(glyph_id)
        @cache[glyph_id] ||= parse_glyph_variations(glyph_id)
      end

      private

      def parse!
        return if @data

        @cache = {}
        io.seek(offset)
        @data = io.read(length)

        @axis_count, @shared_tuple_count, @shared_tuple_offset =
          @data.unpack('@4nnN')
        @glyph_count = @data.unpack1('@12n')
        @flags = @data.unpack1('@14n')
        @glyph_data_offset = @data.unpack1('@16N')
      end

      def long_offsets?
        (@flags & LONG_OFFSETS) == LONG_OFFSETS
      end

      def offsets
        @offsets ||= begin
          entry_size = long_offsets? ? 4 : 2
          start = 20

          Array.new(@glyph_count + 1) do |index|
            position = start + (index * entry_size)
            relative_offset =
              if long_offsets?
                @data[position, 4].unpack1('N')
              else
                @data[position, 2].unpack1('n') * 2
              end

            @glyph_data_offset + relative_offset
          end
        end
      end

      def shared_tuples
        @shared_tuples ||= Array.new(@shared_tuple_count) do |index|
          position = @shared_tuple_offset + (index * @axis_count * 2)
          read_coordinate_at(@data, position).first
        end
      end

      def parse_glyph_variations(glyph_id)
        parse!
        start_position = offsets[glyph_id]
        end_position = offsets[glyph_id + 1]
        data = @data[start_position...end_position]
        return [] if data.empty? || data.length < 4

        tuple_count_and_flags = data.unpack1('n')
        tuple_count = tuple_count_and_flags & TUPLE_COUNT_MASK
        shared_points_flag =
          tuple_count_and_flags & TUPLES_SHARE_POINT_NUMBERS
        tuple_header_size = data.unpack1('@2n')

        position = 4
        data_position = tuple_header_size
        point_count = point_count_for(glyph_id)
        shared_points = []

        if shared_points_flag.nonzero?
          shared_points, data_position =
            read_points(data, data_position, point_count)
        end

        Array.new(tuple_count) do
          data_size, flags = data[position, 4].unpack('n*')
          position += 4

          if (flags & EMBEDDED_PEAK_TUPLE).zero?
            peak = shared_tuples[flags & TUPLE_COUNT_MASK]
          else
            peak, position = read_coordinate_at(data, position)
          end

          if (flags & INTERMEDIATE_REGION).nonzero?
            intermediate_start, position = read_coordinate_at(data, position)
            intermediate_end, position = read_coordinate_at(data, position)
          else
            intermediate_start = peak.transform_values { |value| [value, 0.0].min }
            intermediate_end = peak.transform_values { |value| [value, 0.0].max }
          end

          tuple_delta_position = data_position

          if (flags & PRIVATE_POINT_NUMBERS).nonzero?
            points, tuple_delta_position =
              read_points(data, data_position, point_count)
          else
            points = shared_points
          end

          deltas = parse_deltas(data, tuple_delta_position, points, point_count)
          data_position += data_size

          TupleVariation.new(
            peak: peak,
            intermediate_start: intermediate_start,
            intermediate_end: intermediate_end,
            deltas: deltas,
          )
        end
      end

      def point_count_for(glyph_id)
        glyph = file.glyph_outlines.for(glyph_id)
        outline_points =
          if glyph.nil?
            0
          elsif glyph.compound?
            glyph.glyph_ids.length
          else
            glyph.end_point_of_last_contour
          end

        outline_points + 4
      end

      def read_coordinate_at(data, position)
        coordinate = {}

        file.font_variations.axes.each do |axis|
          coordinate[axis.tag] = signed_short(data[position, 2].unpack1('n')) / 16_384.0
          position += 2
        end

        [coordinate, position]
      end

      def read_points(data, position, point_count)
        count = data.getbyte(position)
        position += 1

        if (count & 0x80).nonzero?
          count = ((count & 0x7f) << 8) | data.getbyte(position)
          position += 1
        end

        return [(0...point_count).to_a, position] if count.zero?

        points = []

        while points.length < count
          header = data.getbyte(position)
          position += 1
          run_count = (header & 0x7f) + 1

          if (header & 0x80).nonzero?
            run_count.times do
              points << data[position, 2].unpack1('n')
              position += 2
            end
          else
            run_count.times do
              points << data.getbyte(position)
              position += 1
            end
          end
        end

        current = 0
        [points.map { |delta| current += delta }, position]
      end

      def parse_deltas(data, position, points, point_count)
        x_values, position = read_delta_run(data, position, points.length)
        y_values, position = read_delta_run(data, position, points.length)
        deltas = Array.new(point_count)

        points.each_with_index do |point, index|
          deltas[point] = [x_values[index], y_values[index]]
        end

        deltas
      end

      def read_delta_run(data, position, count)
        values = []

        while values.length < count
          header = data.getbyte(position)
          position += 1
          run_count = (header & 0x3f) + 1

          case header & 0xc0
          when 0x80
            values.concat(Array.new(run_count, 0))
          when 0x40
            run_count.times do
              values << signed_short(data[position, 2].unpack1('n'))
              position += 2
            end
          when 0xc0
            run_count.times do
              values << signed_long(data[position, 4].unpack1('N'))
              position += 4
            end
          else
            run_count.times do
              values << signed_byte(data.getbyte(position))
              position += 1
            end
          end
        end

        [values, position]
      end

      def signed_byte(value)
        value >= 0x80 ? value - 0x100 : value
      end

      def signed_short(value)
        BinUtils.twos_comp_to_int(value, bit_width: 16)
      end

      def signed_long(value)
        BinUtils.twos_comp_to_int(value, bit_width: 32)
      end
    end
  end
end
