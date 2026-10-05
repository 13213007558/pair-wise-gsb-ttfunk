# frozen_string_literal: true

module TTFunk
  class Table
    # Shared functionality of the embedded/color bitmap tables (`EBLC`,
    # `EBDT`, `CBLC`, `CBDT`).
    module Bitmap
      # Horizontal and vertical metrics of a bitmap strike line.
      LineMetrics = Struct.new(
        :ascender,
        :descender,
        :width_max,
        :caret_slope_numerator,
        :caret_slope_denominator,
        :caret_offset,
        :min_origin_side_bearing,
        :min_advance_side_bearing,
        :max_before_base_line,
        :min_after_base_line,
        keyword_init: true,
      )

      # Horizontal and vertical metrics of a single bitmap glyph.
      GlyphMetrics = Struct.new(
        :width,
        :height,
        :horizontal_bearing_x,
        :horizontal_bearing_y,
        :horizontal_advance,
        :vertical_bearing_x,
        :vertical_bearing_y,
        :vertical_advance,
        keyword_init: true,
      )

      # Reference of one component of a composite bitmap glyph.
      Component = Struct.new(
        :glyph_id,
        :x_offset,
        :y_offset,
        keyword_init: true,
      )

      # Location of a glyph within its data table.
      Location = Struct.new(
        :start_offset,
        :end_offset,
        :image_format,
        :fixed_metrics,
        :fixed_image_size,
        keyword_init: true,
      ) do
        # Whether the glyph has no image data in the strike.
        def empty?
          end_offset <= start_offset
        end

        # Size of the image data in bytes.
        def size
          end_offset - start_offset
        end
      end

      private

      # Read +length+ bytes starting at +position+ and unpack them with
      # +format+. Raises {TTFunk::Error} if the read goes past +limit+.
      def read_unpacked(data, position, length, format, limit = data.bytesize)
        bytes = read_bytes(data, position, length, limit)
        values = bytes.unpack(format)
        values.length == 1 ? values.first : values
      end

      # Slice +length+ bytes starting at +position+, raising a parse error
      # when the requested range is not fully present.
      def read_bytes(data, position, length, limit = data.bytesize)
        if position.negative? || length.negative? || position + length > limit
          raise TTFunk::Error,
            'bitmap table is truncated or contains an invalid offset'
        end

        data.byteslice(position, length)
      end

      def signed_byte(value)
        value >= 0x80 ? value - 0x100 : value
      end
    end
  end
end
