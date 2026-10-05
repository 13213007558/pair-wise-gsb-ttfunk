# frozen_string_literal: true

module TTFunk
  class Table
    class Cbdt < Table
      # Glyph with embedded image data (image formats 17, 18, and 19). The
      # image data is usually a PNG, JPEG, or TIFF image.
      class ImageGlyph < Glyph
        # Embedded image data.
        # @return [String]
        attr_reader :image_data

        # @param image_format [Integer]
        # @param data [String] raw glyph data
        # @param glyph_id [Integer, nil]
        def initialize(image_format, data, glyph_id: nil)
          super(image_format, glyph_id: glyph_id)

          metrics_length =
            case image_format
            when 17
              @metrics = SmallMetrics.from_bytes(data)
              SmallMetrics::BYTE_LENGTH
            when 18
              @metrics = BigMetrics.from_bytes(data)
              BigMetrics::BYTE_LENGTH
            else
              # Format 19 has no metrics.
              0
            end

          if data.bytesize < metrics_length + 4
            raise TTFunk::Error, 'truncated image glyph data'
          end

          data_length = data.byteslice(metrics_length, 4).unpack1('N')

          if data.bytesize < metrics_length + 4 + data_length
            raise TTFunk::Error, 'truncated image glyph image data'
          end

          @image_data = data.byteslice(metrics_length + 4, data_length)
        end
      end
    end
  end
end
