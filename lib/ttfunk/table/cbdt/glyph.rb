# frozen_string_literal: true

require_relative 'metrics'

module TTFunk
  class Table
    class Cbdt < Table
      # Base class for CBDT glyph bitmap data.
      class Glyph
        # Glyph data format.
        # @return [Integer]
        attr_reader :image_format

        # Glyph ID.
        # @return [Integer, nil]
        attr_reader :glyph_id

        # Glyph metrics.
        # @return [TTFunk::Table::Cbdt::SmallMetrics,
        #   TTFunk::Table::Cbdt::BigMetrics, nil]
        attr_reader :metrics

        # Build a glyph object of the appropriate class for the given image
        # format.
        #
        # @param image_format [Integer]
        # @param data [String] raw glyph data
        # @param glyph_id [Integer, nil]
        # @param metrics [TTFunk::Table::Cbdt::BigMetrics, nil] glyph metrics
        #   for formats that don't contain their own
        # @return [TTFunk::Table::Cbdt::Glyph]
        # @raise [TTFunk::Error] on unsupported image format
        def self.for(image_format, data, glyph_id: nil, metrics: nil)
          case image_format
          when 1, 2, 5, 6, 7
            BitmapGlyph.new(
              image_format,
              data,
              glyph_id: glyph_id,
              metrics: metrics,
            )
          when 8, 9
            CompositeGlyph.new(image_format, data, glyph_id: glyph_id)
          when 17, 18, 19
            ImageGlyph.new(image_format, data, glyph_id: glyph_id)
          else
            raise TTFunk::Error,
              "unsupported CBDT image format: #{image_format}"
          end
        end

        # @param image_format [Integer]
        # @param glyph_id [Integer, nil]
        def initialize(image_format, glyph_id: nil)
          @image_format = image_format
          @glyph_id = glyph_id
        end

        # Is this a composite glyph?
        #
        # @return [Boolean]
        def composite?
          false
        end
      end
    end
  end
end

require_relative 'bitmap_glyph'
require_relative 'composite_glyph'
require_relative 'image_glyph'
