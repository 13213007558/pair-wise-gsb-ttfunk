# frozen_string_literal: true

require_relative '../table'
require_relative 'bitmap/common'

module TTFunk
  class Table
    # Color Bitmap Location (`CBLC`) table. Identical in structure to the
    # Embedded Bitmap Location (`EBLC`) table. Each strike references glyph
    # image data stored in the matching {Cbdt} table.
    class Cblc < Table
      include Bitmap

      TAG = 'CBLC'

      # Table tag.
      # @return [String]
      def tag
        TAG
      end

      # A bitmap strike: glyph bitmaps designed for a specific ppem size and
      # bit depth.
      Strike = Struct.new(
        :index,
        :ppem_x,
        :ppem_y,
        :bit_depth,
        :flags,
        :color_ref,
        :start_glyph_index,
        :end_glyph_index,
        :horizontal_metrics,
        :vertical_metrics,
        :index_subtable_array_offset,
        :index_tables_size,
        keyword_init: true,
      )

      # Table version.
      # @return [Integer]
      attr_reader :version

      # Bitmap strikes declared by the table.
      # @return [Array<Strike>]
      attr_reader :strikes

      # Select the strike that best matches the requested ppem and bit depth.
      #
      # Selection order:
      # 1. exact ppem and bit depth,
      # 2. same ppem, preferring the requested bit depth order,
      # 3. nearest ppem (ties resolved towards smaller ppem), preferring the
      #    requested bit depth.
      #
      # The returned strike is always one actually present in the table, so
      # callers can compare its `ppem_x`, `ppem_y` and `bit_depth` against
      # what was requested to detect fallback selection.
      #
      # @param ppem [Integer] requested pixels per em
      # @param bit_depth [Integer, nil] requested bit depth. When nil any bit
      #   depth is accepted.
      # @return [Strike, nil] the selected strike, or nil when the table is
      #   empty
      def strike_for(ppem, bit_depth: nil)
        return if strikes.empty?

        exact_ppem = strikes.select { |strike| strike.ppem_y == ppem }
        candidates = exact_ppem.empty? ? nearest_ppem(ppem) : exact_ppem
        pick(candidates, bit_depth)
      end

      # Location of a glyph within the data table of a strike.
      #
      # @param strike [Strike]
      # @param glyph_id [Integer]
      # @return [Bitmap::Location, nil] glyph location, or nil when the glyph
      #   is not part of the strike or its image is empty
      def location_for(strike, glyph_id)
        return unless within_strike_range?(strike, glyph_id)

        @locations[strike.index][glyph_id]
      end

      private

      def parse!
        data = io.read(length)
        @version = read_unpacked(data, 0, 4, 'N')
        num_sizes = read_unpacked(data, 4, 4, 'N')

        @strikes = []
        @locations = []

        bitmap_size_offset = 8
        num_sizes.times do |strike_index|
          strike, subtables = parse_strike(
            data, strike_index, bitmap_size_offset
          )
          bitmap_size_offset += 48
          @strikes << strike
          @locations << build_locations(data, strike, subtables)
        end
      end

      def parse_strike(data, strike_index, offset)
        index_array_offset, index_tables_size, subtable_count, color_ref =
          read_unpacked(data, offset, 16, 'N4')
        horizontal = parse_line_metrics(data, offset + 16)
        vertical = parse_line_metrics(data, offset + 28)
        part2 = read_unpacked(data, offset + 40, 8, 'n2CCcC')
        start_glyph, end_glyph, ppem_x, ppem_y, bit_depth, flags, _pad = part2

        strike = Strike.new(
          index: strike_index,
          ppem_x: ppem_x,
          ppem_y: ppem_y,
          bit_depth: bit_depth,
          flags: flags,
          color_ref: color_ref,
          start_glyph_index: start_glyph,
          end_glyph_index: end_glyph,
          horizontal_metrics: horizontal,
          vertical_metrics: vertical,
          index_subtable_array_offset: index_array_offset,
          index_tables_size: index_tables_size,
        )

        subtables = parse_index_subtables(
          data, strike, index_array_offset, subtable_count
        )
        [strike, subtables]
      end

      def parse_line_metrics(data, offset)
        ascender, descender, width_max, caret_num, caret_den,
          caret_offset, min_origin_sb, min_advance_sb, max_before_bl,
          min_after_bl = read_unpacked(data, offset, 10, 'c2Cc7')

        LineMetrics.new(
          ascender: ascender,
          descender: descender,
          width_max: width_max,
          caret_slope_numerator: caret_num,
          caret_slope_denominator: caret_den,
          caret_offset: caret_offset,
          min_origin_side_bearing: min_origin_sb,
          min_advance_side_bearing: min_advance_sb,
          max_before_base_line: max_before_bl,
          min_after_base_line: min_after_bl,
        )
      end

      def parse_index_subtables(data, strike, array_offset, count)
        Array.new(count) do |i|
          entry_offset = array_offset + (i * 8)
          first_glyph, last_glyph, additional_offset =
            read_unpacked(data, entry_offset, 8, 'n2N')

          header_offset = array_offset + additional_offset
          index_format, image_format, image_data_offset =
            read_unpacked(data, header_offset, 8, 'n2N')

          {
            first_glyph: first_glyph,
            last_glyph: last_glyph,
            header_offset: header_offset,
            index_format: index_format,
            image_format: image_format,
            image_data_offset: image_data_offset,
            data_limit: data.bytesize,
          }
        end
      end

      def build_locations(data, strike, subtables)
        locations = {}
        subtables.each do |subtable|
          parse_index_subtable(data, subtable).each do |glyph_id, location|
            next if location.empty?

            locations[glyph_id] = location
          end
        end
        locations
      end

      def parse_index_subtable(data, subtable)
        case subtable[:index_format]
        when 1 then offset_array_locations(data, subtable, 'N', 4)
        when 2 then fixed_size_locations(data, subtable)
        when 3 then offset_array_locations(data, subtable, 'n', 2)
        when 4 then code_offset_locations(data, subtable)
        when 5 then composite_locations(data, subtable)
        else
          raise TTFunk::Error, "unsupported bitmap index subtable format "
            "#{subtable[:index_format]}"
        end
      end

      # Index subtables 1 (32-bit offsets) and 3 (16-bit offsets).
      def offset_array_locations(data, subtable, pack_format, offset_size)
        glyph_count = subtable[:last_glyph] - subtable[:first_glyph] + 1
        if glyph_count <= 0
          raise TTFunk::Error, 'invalid bitmap index subtable glyph range'
        end

        # The specification defines glyph_count + 1 offsets, but some widely
        # deployed fonts store one additional trailing offset. Read both
        # tolerantly and only consume the documented number of locations.
        array_offset = subtable[:header_offset] + 8
        offsets = (glyph_count + 1).times.map do |i|
          read_unpacked(
            data,
            array_offset + (i * offset_size),
            offset_size,
            pack_format,
            subtable[:data_limit],
          )
        end
        absolute = offsets.map { |relative| subtable[:image_data_offset] + relative }

        glyph_count.times.filter_map do |i|
          next if absolute[i] == absolute[i + 1]

          [
            subtable[:first_glyph] + i,
            Location.new(
              start_offset: absolute[i],
              end_offset: absolute[i + 1],
              image_format: subtable[:image_format],
            ),
          ]
        end
      end

      # Index subtable 2: all images have identical size and big metrics.
      def fixed_size_locations(data, subtable)
        body_offset = subtable[:header_offset] + 8
        image_size = read_unpacked(
          data, body_offset, 4, 'N', subtable[:data_limit]
        )
        metrics = parse_big_metrics(data, body_offset + 4, subtable[:data_limit])
        glyph_count = subtable[:last_glyph] - subtable[:first_glyph] + 1

        glyph_count.times.map do |i|
          start = subtable[:image_data_offset] + (image_size * i)
          [
            subtable[:first_glyph] + i,
            Location.new(
              start_offset: start,
              end_offset: start + image_size,
              image_format: subtable[:image_format],
              fixed_metrics: metrics,
              fixed_image_size: image_size,
            ),
          ]
        end
      end

      # Index subtable 4: sparse array of glyph code/offset pairs.
      def code_offset_locations(data, subtable)
        body_offset = subtable[:header_offset] + 8
        glyph_count = read_unpacked(
          data, body_offset, 4, 'N', subtable[:data_limit]
        )
        if glyph_count > 0xFFFF
          raise TTFunk::Error, 'invalid bitmap index subtable glyph count'
        end

        array_offset = body_offset + 4
        glyph_ids = glyph_count.times.map do |i|
          read_unpacked(
            data,
            array_offset + (i * 4),
            2,
            'n',
            subtable[:data_limit],
          )
        end
        offsets = (glyph_count + 1).times.map do |i|
          relative = read_unpacked(
            data,
            array_offset + (i * 4) + 2,
            2,
            'n',
            subtable[:data_limit],
          )
          subtable[:image_data_offset] + relative
        end

        glyph_count.times.filter_map do |i|
          next if offsets[i] == offsets[i + 1]

          [
            glyph_ids[i],
            Location.new(
              start_offset: offsets[i],
              end_offset: offsets[i + 1],
              image_format: subtable[:image_format],
            ),
          ]
        end
      end

      # Index subtable 5: sparse array referencing fixed-size composite
      # images (EBDT 8/9 or CBDT 18/19).
      def composite_locations(data, subtable)
        body_offset = subtable[:header_offset] + 8
        image_size = read_unpacked(
          data, body_offset, 4, 'N', subtable[:data_limit]
        )
        metrics = parse_big_metrics(data, body_offset + 4, subtable[:data_limit])
        glyph_count_offset = body_offset + 12
        glyph_count = read_unpacked(
          data, glyph_count_offset, 4, 'N', subtable[:data_limit]
        )
        if glyph_count > 0xFFFF
          raise TTFunk::Error, 'invalid bitmap index subtable glyph count'
        end

        array_offset = glyph_count_offset + 4
        glyph_ids = glyph_count.times.map do |i|
          read_unpacked(
            data,
            array_offset + (i * 2),
            2,
            'n',
            subtable[:data_limit],
          )
        end

        glyph_ids.each_with_index.map do |glyph_id, i|
          start = subtable[:image_data_offset] + (image_size * i)
          [
            glyph_id,
            Location.new(
              start_offset: start,
              end_offset: start + image_size,
              image_format: subtable[:image_format],
              fixed_metrics: metrics,
              fixed_image_size: image_size,
            ),
          ]
        end
      end

      def parse_big_metrics(data, offset, limit)
        height, width, bearing_x, bearing_y, h_advance,
          v_bearing_x, v_bearing_y, v_advance =
          read_unpacked(data, offset, 8, 'CCccCCcc', limit)

        GlyphMetrics.new(
          width: width,
          height: height,
          horizontal_bearing_x: bearing_x,
          horizontal_bearing_y: bearing_y,
          horizontal_advance: h_advance,
          vertical_bearing_x: v_bearing_x,
          vertical_bearing_y: v_bearing_y,
          vertical_advance: v_advance,
        )
      end

      def within_strike_range?(strike, glyph_id)
        glyph_id >= strike.start_glyph_index &&
          glyph_id <= strike.end_glyph_index
      end

      def nearest_ppem(ppem)
        min_distance = strikes.map { |strike|
          (strike.ppem_y - ppem).abs
        }.min
        strikes.select { |strike|
          (strike.ppem_y - ppem).abs == min_distance
        }.sort_by(&:ppem_y)
      end

      def pick(candidates, bit_depth)
        candidates.min_by { |strike|
          [
            bit_depth.nil? ? 0 : (strike.bit_depth == bit_depth ? 0 : 1),
            strike.index,
          ]
        }
      end
    end
  end
end
