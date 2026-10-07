# frozen_string_literal: true

module TTFunk
  module CffToTtf
    # Converts all glyphs of a CFF-based OpenType font to TrueType outlines
    # and assembles the resulting font.
    class Converter
      # @param file [TTFunk::File] CFF-based OpenType font.
      # @param max_error [Numeric] maximum allowed outline deviation in font
      #   units, including integer rounding of point coordinates.
      # @param max_depth [Integer] maximum cubic subdivision depth.
      # @raise [ArgumentError] if the font has no CFF outlines.
      def initialize(file, max_error:, max_depth: PathConverter::DEFAULT_MAX_DEPTH)
        unless file.cff.exists?
          raise ArgumentError, 'font has no CFF outlines'
        end

        @file = file
        @path_converter = PathConverter.new(
          max_error: max_error,
          max_depth: max_depth,
        )
      end

      # Convert the font.
      #
      # The returned result is only complete when every glyph outline was
      # converted within the allowed error. An incomplete result carries no
      # font so that no glyph exceeding the agreed error is ever emitted.
      #
      # @return [TTFunk::CffToTtf::Result]
      def convert
        charstrings = @file.cff.top_index[0].charstrings_index
        glyphs = []
        incomplete_glyphs = []

        @file.maximum_profile.num_glyphs.times do |glyph_id|
          path = charstrings[glyph_id].path
          path_result = @path_converter.convert(path)

          if path_result.complete?
            glyphs << GlyphEncoder.encode(path_result.contours)
          else
            incomplete_glyphs << glyph_id
            glyphs << nil
          end
        rescue RangeError
          # Coordinates don't fit into the glyf table fields.
          incomplete_glyphs << glyph_id
          glyphs << nil
        end

        if incomplete_glyphs.empty?
          Result.new(
            font: Encoder.new(@file, glyphs).encode,
            incomplete_glyphs: [],
          )
        else
          Result.new(font: nil, incomplete_glyphs: incomplete_glyphs)
        end
      end
    end
  end
end
