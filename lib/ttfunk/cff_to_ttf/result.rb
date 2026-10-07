# frozen_string_literal: true

module TTFunk
  module CffToTtf
    # Result of a CFF to TrueType conversion.
    class Result
      # Encoded TrueType font. +nil+ when the conversion is incomplete.
      # @return [String, nil]
      attr_reader :font

      # IDs of glyphs that could not be converted within the allowed error.
      # @return [Array<Integer>]
      attr_reader :incomplete_glyphs

      # @param font [String, nil]
      # @param incomplete_glyphs [Array<Integer>]
      def initialize(font:, incomplete_glyphs:)
        @font = font
        @incomplete_glyphs = incomplete_glyphs
      end

      # Were all glyphs converted within the allowed error?
      #
      # @return [Boolean]
      def complete?
        incomplete_glyphs.empty?
      end
    end
  end
end
