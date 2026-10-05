# frozen_string_literal: true

module TTFunk
  class Table
    class Cblc < Table
      # Line metrics (sbitLineMetrics) for a bitmap strike, either horizontal
      # or vertical.
      class LineMetrics
        # Byte length of the encoded record.
        BYTE_LENGTH = 12

        # Ascender.
        # @return [Integer]
        attr_reader :ascender

        # Descender.
        # @return [Integer]
        attr_reader :descender

        # Maximum advance width.
        # @return [Integer]
        attr_reader :width_max

        # Caret slope numerator.
        # @return [Integer]
        attr_reader :caret_slope_numerator

        # Caret slope denominator.
        # @return [Integer]
        attr_reader :caret_slope_denominator

        # Caret offset.
        # @return [Integer]
        attr_reader :caret_offset

        # Minimum of the origin sidebearings.
        # @return [Integer]
        attr_reader :min_origin_sb

        # Minimum of the advance sidebearings.
        # @return [Integer]
        attr_reader :min_advance_sb

        # Maximum of the before edge bearings.
        # @return [Integer]
        attr_reader :max_before_bl

        # Minimum of the after edge bearings.
        # @return [Integer]
        attr_reader :min_after_bl

        # Parse line metrics from a binary string.
        #
        # @param data [String]
        # @return [TTFunk::Table::Cblc::LineMetrics]
        # @raise [TTFunk::Error] if there's not enough data
        def self.from_bytes(data)
          if data.bytesize < BYTE_LENGTH
            raise TTFunk::Error, 'truncated line metrics'
          end

          new(*data.unpack('c2Cc7'))
        end

        # rubocop:disable Metrics/ParameterLists
        def initialize(
          ascender, descender, width_max, caret_slope_numerator,
          caret_slope_denominator, caret_offset, min_origin_sb, min_advance_sb,
          max_before_bl, min_after_bl
        )
          @ascender = ascender
          @descender = descender
          @width_max = width_max
          @caret_slope_numerator = caret_slope_numerator
          @caret_slope_denominator = caret_slope_denominator
          @caret_offset = caret_offset
          @min_origin_sb = min_origin_sb
          @min_advance_sb = min_advance_sb
          @max_before_bl = max_before_bl
          @min_after_bl = min_after_bl
        end
        # rubocop:enable Metrics/ParameterLists
      end
    end
  end
end
