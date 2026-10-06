# frozen_string_literal: true

module TTFunk
  class Table
    module Variation
      # Decoder for the "Tuple Variation Store" common binary format shared
      # by the `gvar` and `cvar` tables.
      #
      # https://learn.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats
      module TupleVariation
        EMBEDDED_PEAK_TUPLE = 0x8000
        INTERMEDIATE_REGION = 0x4000
        PRIVATE_POINT_NUMBERS = 0x2000

        DELTAS_ARE_ZERO = 0x80
        DELTAS_ARE_WORDS = 0x40
        DELTAS_ARE_LONGS = 0xC0
        DELTAS_SIZE_MASK = 0xC0
        DELTA_RUN_COUNT_MASK = 0x3F

        POINTS_ARE_WORDS = 0x80
        POINT_RUN_COUNT_MASK = 0x7F

        TUPLES_SHARE_POINT_NUMBERS = 0x8000
        TUPLE_COUNT_MASK = 0x0FFF
        TUPLE_INDEX_MASK = 0x0FFF

        # A single (region-scaled) tuple variation.
        #
        # @!attribute axes
        #   @return [Hash{String => Array(Float, Float, Float)}] map from axis
        #     tag to [intermediate_start, peak, intermediate_end] in mapped
        #     normalized coordinates. Axes on which the tuple does not vary
        #     are omitted.
        # @!attribute deltas
        #   @return [Array] deltas. Entries are +nil+ for omitted (IUP)
        #     points. Each entry is an Integer for the single-valued `cvar`
        #     table, or an +[dx, dy]+ pair for the `gvar` table.
        Variation = Struct.new(:axes, :deltas)

        module_function

        # Decode a tuple variation store.
        #
        # @param data [String] raw bytes containing the complete store.
        # @param position [Integer] offset of the tuple variation count word.
        #   The store-local data offset follows it (+position + 2+), and the
        #   first tuple header starts at +position + 4+.
        # @param header_position [Integer] offset of the first tuple header.
        # @param data_position [Integer] offset of the serialized data
        #   section (the first glyph's/table's data, i.e. relative to +data+).
        # @param point_count [Integer] total number of points/cvt entries,
        #   including phantom points for gvar.
        # @param axes [Array<String>] axis tags in fvar order.
        # @param shared_tuples [Array<Hash{String => Float}>] shared peak
        #   tuples decoded from the table header.
        # @param table_tag [String] either `"gvar"` or `"cvar"`.
        # @return [Array<Variation>]
        def decode(data, position, header_position, data_position, point_count, axes,
                   shared_tuples, table_tag)
          tuple_count_word = data[position, 2].unpack1('n')
          shared_points = nil

          share_points =
            (tuple_count_word & TUPLES_SHARE_POINT_NUMBERS) != 0
          if share_points
            # Shared point numbers are encoded at the very start of the
            # serialized data area; the running data cursor advances past
            # them to the first tuple's delta block.
            shared_points, data_cursor =
              decode_points(point_count, data, data_position)
          else
            data_cursor = data_position
          end

          variations = []
          (tuple_count_word & TUPLE_COUNT_MASK).times do
            data_size = data[header_position, 2].unpack1('n')
            flags = data[header_position + 2, 2].unpack1('n')
            tuple_size = tuple_size(flags, axes.length)
            tuple_data = data[header_position, tuple_size]
            header_position += tuple_size
            delta_data = data[data_cursor, data_size]
            data_cursor += data_size
            variations << decode_one(
              tuple_data, delta_data, flags, point_count, axes,
              shared_points, shared_tuples, table_tag
            )
          end
          variations
        end

        def tuple_size(flags, axis_count)
          size = 4
          size += axis_count * 2 if flags & EMBEDDED_PEAK_TUPLE != 0
          size += axis_count * 4 if flags & INTERMEDIATE_REGION != 0
          size
        end

        # Decode a single tuple variation. +tuple_data+ holds the tuple header
        # (data size, flags, optional embedded peak and intermediate region).
        # +delta_data+ holds the serialized data block for this tuple: an
        # optional private point-number list followed by the X and Y (or
        # single, for cvar) delta runs.
        def decode_one(tuple_data, delta_data, flags, point_count, axes,
                       shared_points, shared_tuples, table_tag)
          header_position = 4

          if flags & EMBEDDED_PEAK_TUPLE == 0
            idx = flags & TUPLE_INDEX_MASK
            peak_tuple = shared_tuples[idx]
            if peak_tuple.nil?
              raise Error,
                "invalid variation data: shared tuple #{idx} missing"
            end
          else
            peak_tuple, tuple_position =
              read_coordinates(tuple_data, header_position, axes)
            header_position = tuple_position
          end

          if flags & INTERMEDIATE_REGION != 0
            start_tuple, tuple_position =
              read_coordinates(tuple_data, header_position, axes)
            end_tuple, tuple_position =
              read_coordinates(tuple_data, tuple_position, axes)
          else
            start_tuple = {}
            end_tuple = {}
            peak_tuple.each_key do |tag|
              peak = peak_tuple[tag]
              start_tuple[tag] = [peak, 0.0].min
              end_tuple[tag] = [peak, 0.0].max
            end
          end

          region = {}
          peak_tuple.each_key do |tag|
            peak = peak_tuple[tag].to_f
            start_value = start_tuple[tag].to_f
            end_value = end_tuple[tag].to_f
            next if start_value.zero? && peak.zero? && end_value.zero?

            region[tag] = [start_value, peak, end_value]
          end

          delta_position = 0
          if flags & PRIVATE_POINT_NUMBERS != 0
            points, delta_position =
              decode_points(point_count, delta_data, 0)
          else
            points = shared_points
          end

          deltas = Array.new(point_count)

          if table_tag == 'gvar'
            x_deltas, delta_position =
              decode_deltas(points.length, delta_data, delta_position)
            y_deltas, delta_position =
              decode_deltas(points.length, delta_data, delta_position)

            points.each_with_index do |point, index|
              next unless point >= 0 && point < point_count

              deltas[point] = [x_deltas[index], y_deltas[index]]
            end
          else
            values, delta_position =
              decode_deltas(points.length, delta_data, delta_position)

            points.each_with_index do |point, index|
              next unless point >= 0 && point < point_count

              deltas[point] = values[index]
            end
          end

          Variation.new(region, deltas)
        end

        # Decode the run-length encoded point/cvt number list ("packed
        # points"). Returns [points, new_position]. A count of zero denotes
        # all points, 0...point_count.
        def decode_points(point_count, data, position)
          count = data.getbyte(position)
          position += 1

          if count & POINTS_ARE_WORDS != 0
            count = ((count & POINT_RUN_COUNT_MASK) << 8) |
                    data.getbyte(position)
            position += 1
          end

          if count.zero?
            # A count of zero means every point. The byte still has to be
            # consumed, so delta data begins after it.
            return [(0...point_count).to_a, position]
          end

          points = []
          while points.length < count
            header = data.bytes[position]
            raise Error, 'point run overruns variation data' if header.nil?
            position += 1
            run_count = (header & POINT_RUN_COUNT_MASK) + 1

            if header & POINTS_ARE_WORDS != 0
              values = data[position, run_count * 2].unpack('n*')
              points.concat(values)
              position += run_count * 2
            else
              points.concat(data.bytes[position, run_count] || [])
              position += run_count
            end
          end

          absolute = []
          current = 0
          points.each do |delta|
            current += delta
            absolute << current
          end

          [absolute, position]
        end

        # Decode packed delta values. +length+ is the number of deltas to read.
        # Returns [deltas, new_position].
        def decode_deltas(length, data, position)
          deltas = []

          while deltas.length < length
            header = data.getbyte(position)
            if header.nil?
              raise Error, 'invalid variation delta data: unexpected end'
            end
            position += 1
            run_count = (header & DELTA_RUN_COUNT_MASK) + 1

            case header & DELTAS_SIZE_MASK
            when DELTAS_ARE_ZERO # 0xC0 - note 0x80 alone is "8-bit"
              deltas.concat([0] * run_count)
            when DELTAS_ARE_WORDS
              deltas.concat(data[position, run_count * 2].unpack('s>*'))
              position += run_count * 2
            when DELTAS_ARE_LONGS
              deltas.concat(data[position, run_count * 4].unpack('l>*'))
              position += run_count * 4
            else
              deltas.concat(data[position, run_count].unpack('c*'))
              position += run_count
            end
          end

          [deltas, position]
        end

        # Peak tuple: either embedded (2.14 normalized values) or a shared
        # tuple index.
        # Decode one full normalized coordinate tuple (one F2DOT14 value per
        # axis). Returns [Hash{String => Float}, new_position].
        def read_coordinates(data, position, axes)
          tuple = {}
          axes.each do |tag|
            value = data[position, 2].unpack1('n')
            value -= 0x10000 if value >= 0x8000
            tuple[tag] = value / 16_384.0
            position += 2
          end
          [tuple, position]
        end

      end
    end
  end
end
