# frozen_string_literal: true

require_relative '../table'
require_relative 'math/record'
require_relative 'math/value'
require_relative 'math/device'
require_relative 'math/coverage'
require_relative 'math/constants'
require_relative 'math/glyph_value_table'
require_relative 'math/glyph_info'
require_relative 'math/assembly'
require_relative 'math/construction'
require_relative 'math/variants'

module TTFunk
  class Table
    # OpenType `MATH` table.
    class Math < Table
      TAG = 'MATH'

      attr_reader :major_version
      attr_reader :minor_version
      attr_reader :constants
      attr_reader :glyph_info
      attr_reader :variants

      def constant(name, ppem = nil)
        raise Error, 'MATH table has no math constants table' unless constants

        constants[name, ppem]
      end

      def italic_correction(glyph_id, ppem = nil)
        glyph_info&.italics_correction&.for_glyph(glyph_id, ppem)
      end

      def top_accent_attachment(glyph_id, ppem = nil)
        glyph_info&.top_accent_attachment&.for_glyph(glyph_id, ppem)
      end

      def horizontal_variant(glyph_id, target_size)
        require_variants.horizontal_variant(glyph_id, target_size)
      end

      def vertical_variant(glyph_id, target_size)
        require_variants.vertical_variant(glyph_id, target_size)
      end

      def horizontal_assembly(glyph_id, target_size, ppem = nil)
        require_variants.horizontal_assembly(glyph_id, target_size, ppem)
      end

      def vertical_assembly(glyph_id, target_size, ppem = nil)
        require_variants.vertical_assembly(glyph_id, target_size, ppem)
      end

      def tag
        TAG
      end

      private

      def parse!
        @major_version, @minor_version,
          constants_offset, glyph_info_offset, variants_offset = read(10, 'n*')

        @constants =
          parse_child(Constants, constants_offset, 'math constants')
        @glyph_info =
          parse_child(GlyphInfo, glyph_info_offset, 'math glyph info')
        @variants =
          parse_child(Variants, variants_offset, 'math variants')
      end

      def parse_child(klass, relative_offset, name)
        return if relative_offset.zero?

        absolute = resolve_table_offset(relative_offset, name)
        klass.new(file, absolute, offset, offset + length)
      end

      def resolve_table_offset(relative_offset, name)
        absolute = offset + relative_offset
        if relative_offset.negative? || absolute < offset || absolute >= offset + length
          raise Error, "MATH #{name} offset points outside the table"
        end

        absolute
      end

      def require_variants
        variants || raise(Error, 'MATH table has no math variants table')
      end
    end
  end
end
