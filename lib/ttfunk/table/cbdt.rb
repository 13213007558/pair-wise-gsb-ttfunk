# frozen_string_literal: true

require 'set'
require_relative '../table'
require_relative 'bitmap/common'

module TTFunk
  class Table
    # Color Bitmap Data (`CBDT`) table. Backwards compatible with the
    # Embedded Bitmap Data (`EBDT`) table, so both monochrome/grayscale and
    # color bitmap images are supported.
    class Cbdt < Table
      include Bitmap

      TAG = 'CBDT'

      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

      # Table tag.
      # @return [String]
      def tag
        TAG
      end

      # A decoded bitmap glyph. Inline PNG payloads (formats 16 and 17) are
      # returned as raw PNG data. Composite glyphs (formats 8, 9, 18 and 19)
      # expose their components; when every component is a raw bitmap the
      # composited image is available in `data`.
      BitmapData = Struct.new(
        :format,
        :metrics,
        :data,
        :components,
        :strike,
        keyword_init: true,
      ) do
        # Whether the payload is PNG encoded.
        def png?
          [16, 17].include?(format)
        end

        # Whether the glyph is composed from other bitmap glyphs.
        def composite?
          !components.nil?
        end
      end

      # Table version.
      # @return [Integer]
      attr_reader :version

      # Select the strike best matching the requested ppem and bit depth and
      # decode a glyph's bitmap. See {Cblc#strike_for} for the fallback
      # order. The selected strike is available on the returned bitmap.
      #
      # @param glyph_id [Integer]
      # @param ppem [integer]
      # @param bit_depth [Integer, nil]
      # @return [BitmapData, nil]
      def bitmap_data_for(glyph_id, ppem, bit_depth: nil)
        strike = cblc.strike_for(ppem, bit_depth: bit_depth)
        return if strike.nil?

        glyph_data_for(glyph_id, strike)
      end

      # Decode a glyph's bitmap from an explicitly selected strike.
      #
      # @param glyph_id [Integer]
      # @param strike [Cblc::Strike, nil] strike to read from, defaults to
      #   the first strike
      # @return [BitmapData, nil]
      def glyph_data_for(glyph_id, strike = nil)
        strike ||= cblc.strikes.first
        return if strike.nil?

        location = cblc.location_for(strike, glyph_id)
        return if location.nil?

        decode_glyph(
          glyph_id,
          location,
          strike,
          raw_table,
          {},
          Set.new,
        )
      end

      private

      def cblc
        @cblc ||= Cblc.new(file)
      end

      def parse!
        # Data is read lazily per glyph; only validate the header.
        @version = parse_from(offset) { read(4, 'N').first }
      end

      def raw_table
        @raw_table ||= parse_from(offset) { io.read(length) }
      end

      def decode_glyph(glyph_id, location, strike, data, cache, visiting)
        key = [strike.index, glyph_id]
        return cache[key] if cache.key?(key)
        unless visiting.add?(key)
          raise TTFunk::Error, 'recursive bitmap component cycle detected'
        end

        payload = read_bytes(data, location.start_offset, location.size)
        result =
          case location.image_format
          when 1, 2 then small_metrics_bitmap(payload, location, strike)
          when 5 then fixed_metrics_bitmap(payload, location, strike)
          when 6, 7 then big_metrics_bitmap(payload, location, strike)
          when 8 then composite(payload, location, strike, data, cache, visiting, 8)
          when 9 then composite(payload, location, strike, data, cache, visiting, 9)
          when 16 then png_bitmap(payload, location, strike, true)
          when 17 then png_bitmap(payload, location, strike, false)
          when 18 then composite(payload, location, strike, data, cache, visiting, 18)
          when 19 then composite(payload, location, strike, data, cache, visiting, 19)
          else
            raise TTFunk::Error, "unsupported bitmap image format "
              "#{location.image_format}"
          end

        cache[key] = result
        result
      end

      def small_metrics_bitmap(payload, location, strike)
        metrics = parse_small_metrics(payload, 0, strike)
        BitmapData.new(
          format: location.image_format,
          metrics: metrics,
          data: payload.byteslice(5, payload.bytesize - 5),
          strike: strike,
        )
      end

      def big_metrics_bitmap(payload, location, strike)
        BitmapData.new(
          format: location.image_format,
          metrics: parse_big_metrics(payload, 0),
          data: payload.byteslice(8, payload.bytesize - 8),
          strike: strike,
        )
      end

      # Image formats 5 and 19 carry no inline metrics; they come from the
      # fixed-size index subtable instead.
      def fixed_metrics_bitmap(payload, location, strike)
        metrics = location.fixed_metrics
        if metrics.nil?
          raise TTFunk::Error,
            'bitmap image without inline metrics is not referenced by a '
              'fixed-size index subtable'
        end

        BitmapData.new(
          format: location.image_format,
          metrics: metrics,
          data: payload,
          strike: strike,
        )
      end

      def png_bitmap(payload, location, strike, small)
        small = png_uses_small_metrics?(payload, small)
        if small
          metrics = parse_small_metrics(payload, 0, strike)
          header_size = 5
        else
          metrics = parse_big_metrics(payload, 0)
          header_size = 8
        end

        data_length = read_unpacked(payload, header_size, 4, 'N')
        png_data = read_bytes(
          payload,
          header_size + 4,
          data_length,
          payload.bytesize,
        )

        BitmapData.new(
          format: location.image_format,
          metrics: metrics,
          data: png_data,
          strike: strike,
        )
      end

      # The specification reserves format 17 for big metrics PNGs, but the
      # widely deployed fontTools implementation emits small metrics PNGs with
      # the same format number. Distinguish the two layouts by checking
      # whether the uint32 following big metrics is a plausible data length.
      def png_uses_small_metrics?(payload, small)
        # Format 16 always uses small metrics. Format 17 is big metrics per
        # the specification, but fontTools emits small metrics PNGs with the
        # same format number. Prefer the layout whose declared data length
        # exactly reaches the end of the image record and begins with the PNG
        # signature.
        big_valid = valid_png_record?(payload, 8, 12)
        small_valid = valid_png_record?(payload, 5, 9)
        if small
          small_valid
        elsif big_valid
          false
        else
          small_valid
        end
      end

      def valid_png_record?(payload, length_offset, data_offset)
        return false if payload.bytesize < data_offset + 8

        data_length = read_unpacked(payload, length_offset, 4, 'N')
        data_offset + data_length == payload.bytesize &&
          data_length >= PNG_SIGNATURE.bytesize &&
          payload.byteslice(data_offset, PNG_SIGNATURE.bytesize) == PNG_SIGNATURE
      end

      # Composite image formats:
      # * 8: small metrics, monochrome/grayscale components
      # * 9: big metrics, monochrome/grayscale components
      # * 18: big metrics, color components
      # * 19: fixed metrics, color components
      def composite(payload, location, strike, data, cache, visiting, format)
        case format
        when 8
          metrics = parse_small_metrics(payload, 0, strike)
          component_count = read_unpacked(payload, 6, 2, 'n')
          components_offset = 8
        when 9
          metrics = parse_big_metrics(payload, 0)
          component_count = read_unpacked(payload, 8, 2, 'n')
          components_offset = 10
        when 18
          metrics = parse_big_metrics(payload, 0)
          component_count, components_offset =
            length_encoded_components(payload, 8, 12)
        else
          metrics = location.fixed_metrics
          if metrics.nil?
            raise TTFunk::Error,
              'bitmap image without inline metrics is not referenced by a '
                'fixed-size index subtable'
          end
          # Format 19 stores a uint32 data length followed directly by the
          # component records; there is no component count field.
          component_count, components_offset =
            length_encoded_components(payload, 0, 4)
        end

        components = parse_components(payload, components_offset, component_count)
        children = components.map do |component|
          child_location = cblc.location_for(strike, component.glyph_id)
          if child_location.nil?
            message = "composite bitmap references glyph #{component.glyph_id}"
            raise TTFunk::Error, "#{message} without bitmap data"
          end

          child = decode_glyph(
            component.glyph_id,
            child_location,
            strike,
            data,
            cache,
            visiting,
          )
          [component, child]
        end

        composable = children.none? { |_, child| child.png? || child.composite? }
        composed = compose(children, metrics, strike) if composable

        BitmapData.new(
          format: location.image_format,
          metrics: metrics,
          data: composed,
          components: children.map(&:first),
          strike: strike,
        )
      end

      # Formats 18 and 19 introduce a uint32 data length in place of the
      # explicit component count used by EBDT formats 8 and 9. The component
      # records immediately follow the length field.
      def length_encoded_components(payload, length_offset, records_offset)
        data_length = read_unpacked(payload, length_offset, 4, 'N')
        if data_length % 4 != 0
          raise TTFunk::Error, 'invalid bitmap component data length'
        end
        [data_length / 4, records_offset]
      end

      def parse_components(payload, offset, count)
        Array.new(count) do |i|
          glyph_id, x_offset, y_offset = read_unpacked(
            payload,
            offset + (i * 4),
            4,
            'ncc',
            payload.bytesize,
          )
          Component.new(
            glyph_id: glyph_id,
            x_offset: x_offset,
            y_offset: y_offset,
          )
        end
      end

      # Composite component bitmaps. Monochrome images (formats 8/9) combine
      # overlapping pixels with a Boolean OR, while color images (formats
      # 18/19) use the data of the last component covering a pixel.
      def compose(children, metrics, strike)
        bit_depth = strike.bit_depth
        width = metrics.width
        height = metrics.height
        stride = row_stride(width, bit_depth)
        canvas = "\0".b * (stride * height)
        monochrome = bit_depth == 1

        children.each do |component, child|
          child_metrics = child.metrics
          left = child_metrics.horizontal_bearing_x + component.x_offset
          # Per the EBDT/CBDT specification the component origin is shifted
          # by (xOffset, yOffset) from the composite origin, and the bitmap
          # extends upward from its horizontal bearing.
          top = metrics.horizontal_bearing_y -
            child_metrics.horizontal_bearing_y + component.y_offset
          blit(
            canvas,
            width,
            height,
            stride,
            child,
            left,
            top,
            bit_depth,
            monochrome ? :or : :overwrite,
          )
        end

        canvas
      end

      def blit(canvas, width, height, stride, child, left, top,
               bit_depth, overlap_mode)
        child_metrics = child.metrics
        child_stride = row_stride(child_metrics.width, bit_depth)
        child_data = child.data

        child_metrics.height.times do |y|
          child_metrics.width.times do |x|
            destination_x = left + x
            destination_y = top + y
            next unless destination_x.between?(0, width - 1)
            next unless destination_y.between?(0, height - 1)

            if bit_depth == 1
              source_byte = child_data.getbyte((y * child_stride) + (x / 8)) || 0
              source_bit = source_byte & (0x80 >> (x % 8))
              next if source_bit.zero?

              destination = (destination_y * stride) + (destination_x / 8)
              canvas.setbyte(
                destination,
                canvas.getbyte(destination) | (0x80 >> (destination_x % 8)),
              )
            else
              bytes = pixel_bytes(
                child_data, child_stride, y, x, bit_depth
              )
              destination = (destination_y * stride) +
                (bit_depth == 8 ? destination_x : destination_x * 4)
              bytes.each_with_index do |byte, i|
                canvas.setbyte(destination + i, byte)
              end
            end
          end
        end
      end

      def pixel_bytes(data, stride, y, x, bit_depth)
        if bit_depth == 8
          [data.getbyte((y * stride) + x) || 0]
        elsif bit_depth == 32
          offset = (y * stride) + (x * 4)
          Array.new(4) { |i| data.getbyte(offset + i) || 0 }
        else
          raise TTFunk::Error, "unsupported bitmap bit depth #{bit_depth}"
        end
      end

      def row_stride(width, bit_depth)
        ((bit_depth * width) + 7) / 8
      end

      def parse_small_metrics(payload, offset, strike)
        height, width, bearing_x, bearing_y, advance =
          read_unpacked(payload, offset, 5, 'CCccc')

        horizontal = strike.horizontal_metrics
        vertical = strike.vertical_metrics
        # Per the EBDT specification the vertical metrics of glyphs with
        # small metrics are derived from the strike line metrics.
        vertical_bearing_x = bearing_x + ((advance - width) / 2)
        vertical_bearing_y = bearing_y + horizontal.ascender - vertical.ascender
        vertical_advance = horizontal.ascender - horizontal.descender

        GlyphMetrics.new(
          width: width,
          height: height,
          horizontal_bearing_x: bearing_x,
          horizontal_bearing_y: bearing_y,
          horizontal_advance: advance,
          vertical_bearing_x: vertical_bearing_x,
          vertical_bearing_y: vertical_bearing_y,
          vertical_advance: vertical_advance,
        )
      end

      def parse_big_metrics(payload, offset)
        height, width, bearing_x, bearing_y, h_advance,
          v_bearing_x, v_bearing_y, v_advance =
          read_unpacked(payload, offset, 8, 'CCccCCcc')

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
    end
  end
end
