# frozen_string_literal: true

require_relative '../table'
require_relative 'cbdt/glyph'

module TTFunk
  class Table
    # Color Bitmap Data (CBDT) table. It contains the actual color bitmap
    # glyph data. Glyph data location within this table is described by the
    # CBLC table.
    class Cbdt < Table
      # Table tag.
      TAG = 'CBDT'

      # Table version.
      # @return [Integer]
      attr_reader :version

      # Table tag.
      #
      # @return [String]
      def tag
        TAG
      end

      # Parse glyph bitmap data.
      #
      # @param image_format [Integer] glyph data format
      # @param data_offset [Integer] offset of the glyph data from the
      #   beginning of this table
      # @param data_length [Integer] length of the glyph data in bytes
      # @param glyph_id [Integer, nil] glyph ID, used for error reporting and
      #   composite glyph resolution
      # @param metrics [TTFunk::Table::Cbdt::BigMetrics, nil] glyph metrics
      #   for formats that don't contain their own
      # @return [TTFunk::Table::Cbdt::Glyph]
      # @raise [TTFunk::Error] on malformed font data
      def glyph(image_format, data_offset, data_length, glyph_id: nil, metrics: nil)
        unless exists?
          raise TTFunk::Error, 'CBDT table is missing'
        end

        if data_offset.negative? || data_length.negative? ||
            data_offset + data_length > length
          raise TTFunk::Error,
            "glyph bitmap data at offset #{data_offset} " +              "(#{data_length} bytes) is out of bounds"
        end

        data = parse_from(offset + data_offset) { io.read(data_length) }

        Glyph.for(
          image_format,
          data,
          glyph_id: glyph_id,
          metrics: metrics,
        )
      end

      private

      def parse!
        @version = read(4, 'N').first
      end
    end
  end
end
