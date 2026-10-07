# frozen_string_literal: true

require_relative 'cff_to_ttf/path_converter'
require_relative 'cff_to_ttf/glyph_encoder'
require_relative 'cff_to_ttf/encoder'
require_relative 'cff_to_ttf/converter'
require_relative 'cff_to_ttf/result'

module TTFunk
  # CFF (cubic) to TrueType (quadratic) outline conversion.
  #
  # Some backends only accept TrueType outlines. This module converts the
  # interpreted CFF glyph paths of an OpenType/CFF font into simple +glyf+
  # glyphs and assembles a TrueType font, preserving glyph IDs, the character
  # mapping, and horizontal metrics. CFF hints are not translated to TrueType
  # instructions.
  #
  # @example
  #   result = TTFunk::CffToTtf.convert(TTFunk::File.open('font.otf'), max_error: 1.0)
  #   if result.complete?
  #     File.binwrite('font.ttf', result.font)
  #   end
  module CffToTtf
    # Convert a CFF-based OpenType font to a TrueType font.
    #
    # @param file [TTFunk::File] CFF-based OpenType font.
    # @param max_error [Numeric] maximum allowed outline deviation in font
    #   units, including integer rounding of point coordinates.
    # @param max_depth [Integer] maximum cubic subdivision depth.
    # @return [TTFunk::CffToTtf::Result]
    def self.convert(file, max_error:, max_depth: PathConverter::DEFAULT_MAX_DEPTH)
      Converter.new(file, max_error: max_error, max_depth: max_depth).convert
    end
  end
end
