# frozen_string_literal: true

require_relative '../table'
require_relative 'math/stretch_plan'

module TTFunk
  class Table
    class MathTable < Table
      TAG = 'MATH'
      GlyphVariant = Struct.new(:glyph_id, :advance, keyword_init: true)
      GlyphPart = Struct.new(
        :glyph_id,
        :start_connector_length,
        :end_connector_length,
        :full_advance,
        :extender,
        keyword_init: true,
      ) do
        def extender?
          extender
        end
      end

      GlyphAssembly = Struct.new(
        :italic_correction, :parts, keyword_init: true
      )
      GlyphConstruction = Struct.new(
        :variants, :assembly, keyword_init: true
      )
      MathVariants = Struct.new(
        :min_connector_overlap,
        :vertical_glyphs,
        :horizontal_glyphs,
        keyword_init: true,
      )

      attr_reader :version, :math_constants_offset, :math_glyph_info_offset,
        :math_variants_offset, :variants

      def stretch_plan_for(glyph_id, target_advance, direction = :vertical)
        construction = construction_for(glyph_id, direction)
        StretchPlan.build(
          glyph_id,
          target_advance,
          direction,
          construction,
          variants&.min_connector_overlap || 0,
          method(:italic_correction_for),
        )
      end

      def construction_for(glyph_id, direction)
        return unless variants

        if direction == :horizontal
          coverage_index = @horizontal_coverage.index(glyph_id)
          return unless coverage_index

          variants.horizontal_glyphs[coverage_index]
        else
          coverage_index = @vertical_coverage.index(glyph_id)
          return unless coverage_index

          variants.vertical_glyphs[coverage_index]
        end
      end

      def italic_correction_for(glyph_id)
        @italic_corrections ||= parse_italic_corrections
        @italic_corrections.fetch(glyph_id, 0)
      end

      def tag
        TAG
      end

      private

      def parse!
        @version = read(4, 'N').first
        @math_constants_offset,
          @math_glyph_info_offset,
          @math_variants_offset = read(6, 'n*')

        return if @math_variants_offset.zero?

        variants_base = offset + @math_variants_offset
        parse_from(variants_base) do
          @variants = parse_variants(variants_base)
        end
      end

      def parse_variants(variants_base)
        min_connector_overlap,
          vertical_coverage_offset,
          horizontal_coverage_offset,
          vertical_count,
          horizontal_count = read(10, 'n*')

        vertical_offsets = read_offsets(vertical_count)
        horizontal_offsets = read_offsets(horizontal_count)
        @vertical_coverage = read_coverage(
          variants_base, vertical_coverage_offset
        )
        @horizontal_coverage = read_coverage(
          variants_base, horizontal_coverage_offset
        )

        MathVariants.new(
          min_connector_overlap: min_connector_overlap,
          vertical_glyphs: parse_constructions(
            variants_base, vertical_offsets
          ),
          horizontal_glyphs: parse_constructions(
            variants_base, horizontal_offsets
          ),
        )
      end

      def read_offsets(count)
        count.zero? ? [] : read(count * 2, 'n*')
      end

      def read_coverage(base, coverage_offset)
        return [] if coverage_offset.zero?

        parse_from(base + coverage_offset) do
          format, glyph_count = read(4, 'n*')

          case format
          when 1
            read(glyph_count * 2, 'n*')
          when 2
            Array.new(glyph_count) { read(6, 'n*') }.flat_map do
              |start_glyph, end_glyph, _|
              (start_glyph..end_glyph).to_a
            end
          else
            raise TTFunk::Error,
              "unsupported MATH coverage format #{format}"
          end
        end
      end

      def parse_constructions(variants_base, offsets)
        offsets.map do |construction_offset|
          next nil if construction_offset.zero?

          construction_base = variants_base + construction_offset
          parse_from(construction_base) do
            parse_construction(construction_base)
          end
        end
      end

      def parse_construction(construction_base)
        assembly_offset, variant_count = read(4, 'n*')
        variants = Array.new(variant_count) do
          glyph_id, advance = read(4, 'n*')
          GlyphVariant.new(glyph_id: glyph_id, advance: advance)
        end

        GlyphConstruction.new(
          variants: variants,
          assembly: parse_assembly(construction_base, assembly_offset),
        )
      end

      def parse_assembly(construction_base, assembly_offset)
        return if assembly_offset.zero?

        parse_from(construction_base + assembly_offset) do
          italic_correction = read_signed(1).first
          read(2, 'n') # DeviceTable offset is not needed for geometry.
          part_count = read(2, 'n').first

          parts = Array.new(part_count) do
            glyph_id,
              start_connector_length,
              end_connector_length,
              full_advance,
              flags = read(10, 'n*')

            GlyphPart.new(
              glyph_id: glyph_id,
              start_connector_length: start_connector_length,
              end_connector_length: end_connector_length,
              full_advance: full_advance,
              extender: (flags & 1) == 1,
            )
          end

          GlyphAssembly.new(
            italic_correction: italic_correction,
            parts: parts,
          )
        end
      end

      def parse_italic_corrections
        return {} if @math_glyph_info_offset.nil? ||
          @math_glyph_info_offset.zero?

        glyph_info_base = offset + @math_glyph_info_offset
        parse_from(glyph_info_base) do
          italics_offset,
            _top_accent,
            _extended_shape,
            _math_kern = read(8, 'n*')
          next {} if italics_offset.zero?

          italics_base = glyph_info_base + italics_offset
          parse_from(italics_base) do
            coverage_offset, count = read(4, 'n*')
            glyphs = read_coverage(italics_base, coverage_offset)

            parse_from(italics_base + 4) do
              values = Array.new(count) do
                value = read_signed(1).first
                read(2, 'n')
                value
              end

              glyphs.each_with_index.to_h do |glyph_id, index|
                [glyph_id, values[index]]
              end
            end
          end
        end
      end
    end
  end
end
