# frozen_string_literal: true

module TTFunk
  module Variation
    # Decoder and re-encoder for the outline data of a single `glyf` table
    # entry. Two flavors exist:
    #
    # * {SimpleOutline} decodes every point of a simple glyph and can
    #   re-encode the glyph with new point coordinates and bounding box.
    # * {CompoundOutline} only parses the component records (which are all
    #   the `gvar` table is able to move) and re-encodes with new component
    #   translations and bounding box.
    #
    # Coordinate and bounding-box fields are all signed 16-bit integers.
    module GlyphOutline
      X_SHORT = 0x02
      Y_SHORT = 0x04
      ON_CURVE = 0x01
      REPEAT = 0x08
      X_SAME = 0x10
      Y_SAME = 0x20
      OVERLAP_SIMPLE = 0x40

      ARG_1_AND_2_ARE_WORDS = 0x0001
      WE_HAVE_A_SCALE = 0x0008
      MORE_COMPONENTS = 0x0020
      WE_HAVE_AN_X_AND_Y_SCALE = 0x0040
      WE_HAVE_A_TWO_BY_TWO = 0x0080
      WE_HAVE_INSTRUCTIONS = 0x0100

      # @return [Integer] signed 16-bit minimum x of the glyph bounding box.
      attr_reader :x_min, :y_min, :x_max, :y_max

      # Replace the glyph's bounding box.
      #
      # @param bounds [Array(Integer, Integer, Integer, Integer)]
      #   xMin, yMin, xMax, yMax.
      # @return [void]
      def bounds=(bounds)
        @x_min, @y_min, @x_max, @y_max = bounds
      end

      private

      def pack_bounds
        [x_min, y_min, x_max, y_max].pack('s>*')
      end
    end
  end
end

require_relative 'glyph_outline/simple_outline'
require_relative 'glyph_outline/compound_outline'
