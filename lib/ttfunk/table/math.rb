# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Mathematical typesetting (`MATH`) table.
    class Math < Table
      TAG = 'MATH'
      VERTICAL = :vertical
      HORIZONTAL = :horizontal

      Variant = Struct.new(:glyph_id, :advance_measurement, :italic_correction)
      Part = Struct.new(
        :glyph_id,
        :start_connector_length,
        :end_connector_length,
        :full_advance,
        :extender,
      ) do
        def extender?
          extender
        end
      end

      Assembly = Struct.new(:italic_correction, :parts)
      Construction = Struct.new(:assembly, :variants)
      Segment = Struct.new(:glyph_id, :position, :advance, :end_position)
      Stretch = Struct.new(
        :glyph_id,
        :target_advance,
        :actual_advance,
        :italic_correction,
        :direction,
        :variant,
        :segments,
      ) do
        def variant?
          variant
        end

        def assembly?
          !variant
        end
      end

      # Table version.
      # @return [Integer]
      attr_reader :version

      # Italics corrections keyed by glyph ID.
      # @return [Hash{Integer => Integer}]
      attr_reader :italic_corrections

      def tag
        TAG
      end

      # Choose a large variant or construct an assembly for a glyph.
      #
      # @param glyph_id [Integer]
      # @param target_advance [Integer]
      # @param direction [:vertical, :horizontal]
      # @return [Stretch]
      def stretch(glyph_id, target_advance, direction)
        verify_target(glyph_id, target_advance, direction)

        construction = construction_for(glyph_id, direction)
        raise_unstretchable(glyph_id) unless construction

        variant = fitting_variant(construction, glyph_id, target_advance)
        return stretch_from_variant(variant, target_advance, direction) if variant

        assembly = construction.assembly
        unless assembly
          raise TTFunk::Error,
            "glyph #{glyph_id} has no #{direction} glyph assembly " \
              "large enough for #{target_advance}"
        end

        stretch_from_assembly(assembly, glyph_id, target_advance, direction)
      end

      private

      def parse!
        @version = read(4, 'N').first
        _constants_offset, glyph_info_offset, variants_offset = read(6, 'n*')

        @italic_corrections = {}
        parse_italic_corrections(glyph_info_offset)
        parse_math_variants(variants_offset)
      end

      def parse_italic_corrections(glyph_info_offset)
        @italic_corrections ||= {}
        return if glyph_info_offset.zero?

        parse_from(offset + glyph_info_offset) do
          italics_offset = read(2, 'n').first
          next if italics_offset.zero?

          parse_from(offset + glyph_info_offset + italics_offset) do
            coverage_offset, count = read(4, 'n*')
            italics_base = offset + glyph_info_offset + italics_offset
            glyphs = parse_coverage(italics_base + coverage_offset)
            glyphs.each do |glyph_id|
              value, _device_offset = read(4, 'n*')
              @italic_corrections[glyph_id] = to_signed(value)
            end
          end
        end
      end

      def parse_math_variants(variants_offset)
        @vertical_glyphs = []
        @horizontal_glyphs = []
        @vertical_construction_offsets = []
        @horizontal_construction_offsets = []
        @vertical_glyph_count = 0
        @horizontal_glyph_count = 0
        return if variants_offset.zero?

        @math_variants_offset = variants_offset

        parse_from(offset + variants_offset) do
          @min_connector_overlap,
            vertical_coverage_offset,
            horizontal_coverage_offset,
            @vertical_glyph_count,
            @horizontal_glyph_count = read(10, 'n*')

          construction_arrays_offset = 10
          @vertical_construction_offsets =
            parse_from(offset + variants_offset + construction_arrays_offset) do
              read(@vertical_glyph_count * 2, 'n*')
            end
          @horizontal_construction_offsets =
            parse_from(
              offset + variants_offset + construction_arrays_offset +
                (@vertical_glyph_count * 2)
            ) do
              read(@horizontal_glyph_count * 2, 'n*')
            end

          @vertical_glyphs =
            if vertical_coverage_offset.zero?
              []
            else
              parse_coverage(offset + variants_offset + vertical_coverage_offset)
            end
          @horizontal_glyphs =
            if horizontal_coverage_offset.zero?
              []
            else
              parse_coverage(offset + variants_offset + horizontal_coverage_offset)
            end
        end
      end

      def parse_construction(construction_offset)
        parse_from(construction_offset) do
          assembly_offset, variant_count = read(4, 'n*')
          variants = Array.new(variant_count) do
            glyph_id, advance = read(4, 'n*')
            italic_correction = @italic_corrections.fetch(glyph_id, 0)
            Variant.new(glyph_id, advance, italic_correction)
          end
          unless assembly_offset.zero?
            assembly = parse_assembly(construction_offset + assembly_offset)
          end
          Construction.new(assembly, variants)
        end
      end

      def parse_assembly(assembly_offset)
        parse_from(assembly_offset) do
          value, _device_offset, part_count = read(6, 'n*')
          parts = Array.new(part_count) do
            glyph_id,
              start_connector,
              end_connector,
              full_advance,
              flags = read(10, 'n*')
            Part.new(
              glyph_id,
              start_connector,
              end_connector,
              full_advance,
              flags.anybits?(1),
            )
          end
          Assembly.new(to_signed(value), parts)
        end
      end

      def parse_coverage(coverage_offset)
        parse_from(coverage_offset) do
          format, count = read(4, 'n*')

          case format
          when 1
            read(count * 2, 'n*')
          when 2
            ranges = Array.new(count) { read(6, 'n*') }
            pairs =
              ranges.flat_map do |start_glyph_id, end_glyph_id, start_index|
                (start_glyph_id..end_glyph_id).each_with_index.map do |glyph_id, range_index|
                  [start_index + range_index, glyph_id]
                end
              end.sort.map(&:last)
            pairs
          else
            raise TTFunk::Error, "unsupported MATH coverage format #{format}"
          end
        end
      end

      def verify_target(glyph_id, target_advance, direction)
        unless glyph_id.is_a?(Integer) && glyph_id >= 0
          raise ArgumentError, 'glyph_id must be a non-negative Integer'
        end

        unless target_advance.is_a?(Integer) && target_advance >= 0
          raise ArgumentError, 'target_advance must be a non-negative Integer'
        end

        unless [VERTICAL, HORIZONTAL].include?(direction)
          raise ArgumentError, 'direction must be :vertical or :horizontal'
        end
      end

      def construction_for(glyph_id, direction)
        glyphs, count, offsets =
          if direction == VERTICAL
            [@vertical_glyphs, @vertical_glyph_count, @vertical_construction_offsets]
          else
            [
              @horizontal_glyphs,
              @horizontal_glyph_count,
              @horizontal_construction_offsets,
            ]
          end

        index = glyphs.index(glyph_id)
        return unless index && index < count

        @construction_cache ||= {}
        cache_key = [direction, index]
        if @construction_cache.key?(cache_key)
          return @construction_cache[cache_key]
        end

        construction_offset = offsets[index]
        return if construction_offset.zero?

        @construction_cache[[direction, index]] =
          parse_construction(
            offset + @math_variants_offset + construction_offset
          )
      end

      def fitting_variant(construction, glyph_id, target_advance)
        candidates = construction.variants.select do |variant|
          variant.advance_measurement >= target_advance
        end

        return candidates.min_by(&:advance_measurement) if candidates.any?

        nil
      end

      def assembly_advance(assembly, counts)
        parts = expand_parts(assembly.parts, counts)
        overlaps = connector_overlaps(parts)
        return nil unless overlaps

        parts.sum(&:full_advance) - overlaps.sum(&:first)
      end

      def connector_overlaps(parts)
        return [] if parts.length <= 1

        parts.each_cons(2).map do |first, second|
          maximum_overlap = [
            first.end_connector_length,
            second.start_connector_length,
            first.full_advance,
            second.full_advance,
          ].min
          return if maximum_overlap.negative?

          [maximum_overlap, @min_connector_overlap]
        end
      end

      def stretch_from_variant(variant, target_advance, direction)
        Stretch.new(
          variant.glyph_id,
          target_advance,
          variant.advance_measurement,
          variant.italic_correction,
          direction,
          true,
          [
            Segment.new(
              variant.glyph_id,
              0,
              variant.advance_measurement,
              variant.advance_measurement,
            )
          ],
        )
      end

      def stretch_from_assembly(assembly, glyph_id, target_advance, direction)
        counts = fitting_counts(assembly, target_advance)

        unless counts
          raise TTFunk::Error,
            "glyph #{glyph_id} cannot be assembled to advance #{target_advance} " \
              "(#{direction}); " \
              'no extender repetition can reach it with the permitted connector overlaps'
        end

        parts = expand_parts(assembly.parts, counts)
        maximum_overlaps = connector_overlaps(parts).map(&:first)
        minimum_advance = parts.sum(&:full_advance) - maximum_overlaps.sum
        maximum_advance =
          parts.sum(&:full_advance) - (@min_connector_overlap * maximum_overlaps.length)

        if target_advance > maximum_advance
          raise TTFunk::Error,
            "glyph #{glyph_id} cannot be assembled to advance #{target_advance} " \
              "(#{direction})"
        end

        actual_advance = [target_advance, minimum_advance].max
        overlaps = overlaps_for_target(
          maximum_overlaps,
          actual_advance - minimum_advance,
        )
        Stretch.new(
          glyph_id,
          target_advance,
          actual_advance,
          assembly.italic_correction,
          direction,
          false,
          segments_for(parts, overlaps),
        )
      end

      def fitting_counts(assembly, target_advance)
        extender_indexes =
          assembly.parts.each_index.select { |index| assembly.parts[index].extender? }
        return repeated_counts(assembly) if extender_indexes.empty?

        repeatable_extenders = extender_indexes.select do |index|
          repeatable_part?(assembly.parts[index])
        end
        return if repeatable_extenders.empty?

        base_counts = repeated_counts(assembly)
        base_advance = assembly_advance(assembly, base_counts)
        return unless base_advance

        growths = repeatable_extenders.map do |index|
          assembly.parts[index].full_advance - @min_connector_overlap
        end
        maximum_growth = growths.max
        total_added =
          if maximum_growth.positive?
            Rational([0, target_advance - base_advance].max, maximum_growth).ceil
          else
            0
          end

        loop do
          added_counts = minimal_extender_distribution(
            extender_indexes,
            repeatable_extenders,
            growths,
            total_added,
          )
          counts = repeated_counts(assembly, extender_indexes, added_counts)
          advance = assembly_advance(assembly, counts)
          return counts if advance && advance >= target_advance

          total_added += 1
        end
      end

      def minimal_extender_distribution(
        extender_indexes,
        repeatable_extenders,
        growths,
        total_added
      )
        remaining = total_added

        extender_indexes.map do |part_index|
          repeatable_index = repeatable_extenders.index(part_index)
          next 0 unless repeatable_index

          later_growth = growths[(repeatable_index + 1)..].to_a.max || 0
          retain = later_growth.zero? ? 0 : (remaining / later_growth) * later_growth
          added = [remaining - retain, 0].max
          remaining -= added
          added
        end
      end

      def repeatable_part?(part)
        [
          part.start_connector_length,
          part.end_connector_length,
          part.full_advance,
        ].min >= @min_connector_overlap
      end

      def repeated_counts(assembly, extender_indexes = nil, added_counts = nil)
        extender_indexes ||=
          assembly.parts.each_index.select do |index|
            assembly.parts[index].extender?
          end
        added_counts ||= Array.new(extender_indexes.length, 0)
        additions = extender_indexes.zip(added_counts).to_h
        assembly.parts.each_index.map { |index| 1 + additions.fetch(index, 0) }
      end

      def expand_parts(parts, counts)
        parts.flat_map.with_index do |part, index|
          [part] * counts[index]
        end
      end

      def overlaps_for_target(maximum_overlaps, slack)
        remaining_slack = slack

        maximum_overlaps.map do |maximum_overlap|
          decrease = [
            remaining_slack,
            maximum_overlap - @min_connector_overlap,
          ].min
          remaining_slack -= decrease
          maximum_overlap - decrease
        end
      end

      def segments_for(parts, overlaps)
        position = 0

        parts.map.with_index do |part, index|
          advance =
            if index == parts.length - 1
              part.full_advance
            else
              part.full_advance - overlaps[index]
            end
          end_position = position + part.full_advance
          segment = Segment.new(part.glyph_id, position, advance, end_position)
          position += advance
          segment
        end
      end

      def raise_unstretchable(glyph_id)
        raise TTFunk::Error,
          "glyph #{glyph_id} is not covered by the MATH MathVariants table"
      end
    end
  end
end
