# frozen_string_literal: true

require_relative '../table'
require_relative 'cblc/strike'

module TTFunk
  class Table
    # Color Bitmap Location (CBLC) table. It provides information about the
    # location of color bitmap glyphs in the CBDT table. Glyphs are
    # organized in strikes. Each strike is a set of bitmaps for all (or most)
    # glyphs at a given pixels-per-em (ppem) size and bit depth.
    class Cblc < Table
      # Table tag.
      TAG = 'CBLC'

      # Table version.
      # @return [Integer]
      attr_reader :version

      # Bitmap strikes.
      # @return [Array<TTFunk::Table::Cblc::Strike>]
      attr_reader :strikes

      # Glyph bitmap along with the strike it was taken from. Since strike
      # selection can fall back to a different ppem or bit depth than
      # requested, the selected strike is exposed so callers can tell whether
      # the result is exactly what they asked for.
      class BitmapSelection
        # The strike the bitmap was taken from.
        # @return [TTFunk::Table::Cblc::Strike]
        attr_reader :strike

        # The glyph bitmap. It is +nil+ when the glyph has no bitmap in the
        # selected strike.
        # @return [TTFunk::Table::Cbdt::Glyph, nil]
        attr_reader :glyph

        # @param strike [TTFunk::Table::Cblc::Strike]
        # @param glyph [TTFunk::Table::Cbdt::Glyph, nil]
        def initialize(strike, glyph)
          @strike = strike
          @glyph = glyph
        end

        # Does the selected strike exactly match the requested ppem and bit
        # depth?
        #
        # @param ppem [Integer]
        # @param bit_depth [Integer, nil]
        # @return [Boolean]
        def exact_match?(ppem, bit_depth: nil)
          strike.ppem_x == ppem && strike.ppem_y == ppem &&
            (bit_depth.nil? || strike.bit_depth == bit_depth)
        end
      end

      # Table tag.
      #
      # @return [String]
      def tag
        TAG
      end

      # Select the best strike for the given ppem and bit depth.
      #
      # Selection degrades gracefully:
      # 1. Strikes with the requested bit depth are preferred. If no strike
      #    has the requested bit depth, all strikes are considered.
      # 2. A strike with the exact ppem is preferred.
      # 3. Otherwise the strike with the closest ppem is chosen, preferring
      #    the larger strike on ties.
      #
      # @param ppem [Integer] desired pixels-per-em
      # @param bit_depth [Integer, nil] desired bit depth
      # @return [TTFunk::Table::Cblc::Strike, nil] the selected strike or
      #   +nil+ if there are no strikes
      def strike_for(ppem, bit_depth: nil)
        return nil if strikes.empty?

        candidates = strikes

        if bit_depth
          matching_depth = candidates.select { |strike| strike.bit_depth == bit_depth }
          candidates = matching_depth unless matching_depth.empty?
        end

        exact = candidates.find { |strike| strike.ppem_x == ppem && strike.ppem_y == ppem }
        return exact if exact

        candidates.min_by { |strike| [(strike.ppem_x - ppem).abs, -strike.ppem_x] }
      end

      # Find the bitmap for the given glyph at the requested size.
      #
      # @param glyph_id [Integer]
      # @param ppem [Integer] desired pixels-per-em
      # @param bit_depth [Integer, nil] desired bit depth
      # @return [TTFunk::Table::Cblc::BitmapSelection, nil] the selected
      #   strike along with the glyph bitmap, or +nil+ if no strike is
      #   available
      def bitmap_for(glyph_id, ppem:, bit_depth: nil)
        strike = strike_for(ppem, bit_depth: bit_depth)
        return nil if strike.nil?

        BitmapSelection.new(strike, strike.bitmap_for(glyph_id))
      end

      private

      def parse!
        @version, num_sizes = read(8, 'N2')

        if 8 + (num_sizes * Strike::RECORD_LENGTH) > length
          raise TTFunk::Error, "CBLC table is truncated: #{num_sizes} strikes don't fit"
        end

        @strikes = Array.new(num_sizes) { |index| Strike.new(self, index) }
      end
    end
  end
end
