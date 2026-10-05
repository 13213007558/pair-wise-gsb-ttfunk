# frozen_string_literal: true

module TTFunk
  class Table
    class Cbdt < Table
      # Small glyph metrics. Contains only horizontal metrics.
      class SmallMetrics
        # Byte length of the encoded record.
        BYTE_LENGTH = 5

        # Height of the bitmap in pixels.
        # @return [Integer]
        attr_reader :height

        # Width of the bitmap in pixels.
        # @return [Integer]
        attr_reader :width

        # Horizontal distance from the glyph origin to the left edge of the
        # bitmap.
        # @return [Integer]
        attr_reader :bearing_x

        # Horizontal distance from the glyph origin (on the baseline) to the
        # top edge of the bitmap.
        # @return [Integer]
        attr_reader :bearing_y

        # Horizontal advance.
        # @return [Integer]
        attr_reader :advance

        # Parse small metrics from a binary string.
        #
        # @param data [String]
        # @return [TTFunk::Table::Cbdt::SmallMetrics]
        # @raise [TTFunk::Error] if there's not enough data
        def self.from_bytes(data)
          if data.bytesize < BYTE_LENGTH
            raise TTFunk::Error, 'truncated glyph metrics'
          end

          new(*data.unpack('C2c2C'))
        end

        def initialize(height, width, bearing_x, bearing_y, advance)
          @height = height
          @width = width
          @bearing_x = bearing_x
          @bearing_y = bearing_y
          @advance = advance
        end

        # Are these big metrics?
        #
        # @return [false]
        def big?
          false
        end

        # Horizontal distance from the glyph origin to the left edge of the
        # bitmap.
        #
        # @return [Integer]
        def hori_bearing_x
          bearing_x
        end

        # Horizontal distance from the glyph origin to the top edge of the
        # bitmap.
        #
        # @return [Integer]
        def hori_bearing_y
          bearing_y
        end

        # Horizontal advance.
        #
        # @return [Integer]
        def hori_advance
          advance
        end

        # Vertical metrics are not available in small metrics.
        #
        # @return [nil]
        def vert_bearing_x
          nil
        end

        # Vertical metrics are not available in small metrics.
        #
        # @return [nil]
        def vert_bearing_y
          nil
        end

        # Vertical metrics are not available in small metrics.
        #
        # @return [nil]
        def vert_advance
          nil
        end
      end

      # Big glyph metrics. Contains both horizontal and vertical metrics.
      class BigMetrics
        # Byte length of the encoded record.
        BYTE_LENGTH = 8

        # Height of the bitmap in pixels.
        # @return [Integer]
        attr_reader :height

        # Width of the bitmap in pixels.
        # @return [Integer]
        attr_reader :width

        # Horizontal distance from the glyph origin to the left edge of the
        # bitmap.
        # @return [Integer]
        attr_reader :hori_bearing_x

        # Horizontal distance from the glyph origin (on the baseline) to the
        # top edge of the bitmap.
        # @return [Integer]
        attr_reader :hori_bearing_y

        # Horizontal advance.
        # @return [Integer]
        attr_reader :hori_advance

        # Vertical distance from the glyph origin to the left edge of the
        # bitmap.
        # @return [Integer]
        attr_reader :vert_bearing_x

        # Vertical distance from the glyph origin to the top edge of the
        # bitmap.
        # @return [Integer]
        attr_reader :vert_bearing_y

        # Vertical advance.
        # @return [Integer]
        attr_reader :vert_advance

        # Parse big metrics from a binary string.
        #
        # @param data [String]
        # @return [TTFunk::Table::Cbdt::BigMetrics]
        # @raise [TTFunk::Error] if there's not enough data
        def self.from_bytes(data)
          if data.bytesize < BYTE_LENGTH
            raise TTFunk::Error, 'truncated glyph metrics'
          end

          new(*data.unpack('C2c2Cc2C'))
        end

        # rubocop:disable Metrics/ParameterLists
        def initialize(
          height, width, hori_bearing_x, hori_bearing_y, hori_advance,
          vert_bearing_x, vert_bearing_y, vert_advance
        )
          @height = height
          @width = width
          @hori_bearing_x = hori_bearing_x
          @hori_bearing_y = hori_bearing_y
          @hori_advance = hori_advance
          @vert_bearing_x = vert_bearing_x
          @vert_bearing_y = vert_bearing_y
          @vert_advance = vert_advance
        end
        # rubocop:enable Metrics/ParameterLists

        # Are these big metrics?
        #
        # @return [true]
        def big?
          true
        end

        # Horizontal distance from the glyph origin to the left edge of the
        # bitmap.
        #
        # @return [Integer]
        def bearing_x
          hori_bearing_x
        end

        # Horizontal distance from the glyph origin to the top edge of the
        # bitmap.
        #
        # @return [Integer]
        def bearing_y
          hori_bearing_y
        end

        # Horizontal advance.
        #
        # @return [Integer]
        def advance
          hori_advance
        end
      end
    end
  end
end
