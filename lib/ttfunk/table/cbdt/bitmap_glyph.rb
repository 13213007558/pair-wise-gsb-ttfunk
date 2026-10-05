# frozen_string_literal: true

module TTFunk
  class Table
    class Cbdt < Table
      # Bit-aligned and byte-aligned monochrome bitmap glyph (image formats
      # 1, 2, 5, 6, and 7).
      class BitmapGlyph < Glyph
        # Image formats with byte-aligned bitmap rows.
        BYTE_ALIGNED_FORMATS = [1, 6].freeze

        # Image formats with small metrics.
        SMALL_METRICS_FORMATS = [1, 2].freeze

        # Image formats with big metrics.
        BIG_METRICS_FORMATS = [6, 7].freeze

        # @param image_format [Integer]
        # @param data [String] raw glyph data
        # @param glyph_id [Integer, nil]
        # @param metrics [TTFunk::Table::Cbdt::BigMetrics, nil] glyph metrics
        #   for format 5 that doesn't contain its own
        def initialize(image_format, data, glyph_id: nil, metrics: nil)
          super(image_format, glyph_id: glyph_id)

          if SMALL_METRICS_FORMATS.include?(image_format)
            @metrics = SmallMetrics.from_bytes(data)
            @bitmap_data = data.byteslice(SmallMetrics::BYTE_LENGTH..)
          elsif BIG_METRICS_FORMATS.include?(image_format)
            @metrics = BigMetrics.from_bytes(data)
            @bitmap_data = data.byteslice(BigMetrics::BYTE_LENGTH..)
          else
            # Format 5: metrics are stored in the CBLC index subtable.
            if metrics.nil?
              raise TTFunk::Error,
                'image format 5 requires metrics from the index subtable'
            end

            @metrics = metrics
            @bitmap_data = data
          end

          if @bitmap_data.bytesize < bitmap_data_length
            raise TTFunk::Error, 'truncated glyph bitmap data'
          end
        end

        # Are bitmap rows padded to whole bytes?
        #
        # @return [Boolean]
        def byte_aligned?
          BYTE_ALIGNED_FORMATS.include?(image_format)
        end

        # Bitmap width in pixels.
        #
        # @return [Integer]
        def width
          metrics.width
        end

        # Bitmap height in pixels.
        #
        # @return [Integer]
        def height
          metrics.height
        end

        # Bitmap pixels. Each row is an array of 0s and 1s. Rows are ordered
        # from top to bottom, pixels in a row from left to right.
        #
        # @return [Array<Array<Integer>>]
        def pixels
          bits = @bitmap_data.unpack1('B*')

          if byte_aligned?
            row_bits = ((width + 7) / 8) * 8
            Array.new(height) { |row|
              bits[(row * row_bits), width].chars.map(&:to_i)
            }
          else
            Array.new(height) { |row|
              bits[(row * width), width].chars.map(&:to_i)
            }
          end
        end

        private

        def bitmap_data_length
          if byte_aligned?
            ((width + 7) / 8) * height
          else
            (width * height + 7) / 8
          end
        end
      end
    end
  end
end
