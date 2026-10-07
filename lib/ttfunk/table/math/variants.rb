# frozen_string_literal: true

require_relative 'construction'
require_relative 'coverage'
require_relative 'record'

module TTFunk
  class Table
    class Math < Table
      # Horizontal and vertical glyph variants and assemblies.
      class Variants < Record
        attr_reader :min_connector_overlap
        attr_reader :vertical_coverage
        attr_reader :horizontal_coverage
        attr_reader :vertical_constructions
        attr_reader :horizontal_constructions

        def horizontal_variant(glyph_id, target_size)
          choose_glyph(glyph_id, target_size, Assembly::HORIZONTAL)
        end

        def vertical_variant(glyph_id, target_size)
          choose_glyph(glyph_id, target_size, Assembly::VERTICAL)
        end

        def horizontal_assembly(glyph_id, target_size, ppem = nil)
          assemble_glyph(glyph_id, target_size, Assembly::HORIZONTAL, ppem)
        end

        def vertical_assembly(glyph_id, target_size, ppem = nil)
          assemble_glyph(glyph_id, target_size, Assembly::VERTICAL, ppem)
        end

        private

        def parse!
          @min_connector_overlap = read_int16
          vertical_coverage_offset, horizontal_coverage_offset,
            vertical_count, horizontal_count = read(8, 'n*')

          @vertical_coverage = parse_coverage(vertical_coverage_offset, 'vertical coverage')
          @horizontal_coverage = parse_coverage(horizontal_coverage_offset, 'horizontal coverage')
          @vertical_constructions = parse_constructions(vertical_count, Assembly::VERTICAL)
          @horizontal_constructions = parse_constructions(horizontal_count, Assembly::HORIZONTAL)
        end

        def parse_coverage(offset, name)
          malformed!("#{name} offset is zero") if offset.zero?

          absolute = resolve_offset(table_offset, offset, name)
          Coverage.new(file, absolute, root_start, root_end)
        end

        def parse_constructions(count, orientation)
          offsets = Array.new(count) { read_offset }
          offsets.map do |construction_offset|
            next if construction_offset.zero?

            absolute =
              resolve_offset(table_offset, construction_offset, 'glyph construction')
            Construction.new(file, absolute, root_start, root_end, orientation)
          end
        end

        def choose_glyph(glyph_id, target_size, orientation)
          construction = construction_for(glyph_id, orientation)
          base = base_variant(glyph_id)
          return variant_result(base, orientation) if construction.nil?
          return variant_result(base, orientation) if target_size <= base.advance_measurement

          candidates = variant_candidates(construction)
          variant = candidates.sort_by(&:advance_measurement).find do |candidate|
            candidate.advance_measurement >= target_size
          end

          if variant
            variant_result(variant, orientation)
          else
            assemble_glyph(glyph_id, target_size, orientation)
          end
        end

        def variant_candidates(construction)
          construction.variants.dup
        end

        def variant_result(variant, orientation)
          {
            glyph: variant.glyph_id,
            glyphs: [variant.glyph_id],
            parts: [part_for(variant)],
            size: variant.advance_measurement,
            repeat_count: 0,
            assembly: false,
            orientation: orientation,
          }
        end

        def base_variant(glyph_id)
          Variant.new(
            glyph_id: glyph_id,
            advance_measurement: base_size(glyph_id),
          )
        end

        def assemble_glyph(glyph_id, target_size, orientation, ppem = nil)
          construction = construction_for(glyph_id, orientation)
          unless construction&.assembly
            raise Error, "MATH table has no #{orientation} glyph for target size #{target_size}"
          end

          construction.assembly.assemble(
            target_size, ppem, min_connector_overlap
          )
        end

        def construction_for(glyph_id, orientation)
          index =
            if orientation == Assembly::HORIZONTAL
              horizontal_coverage.index_for(glyph_id)
            else
              vertical_coverage.index_for(glyph_id)
            end

          return unless index

          constructions =
            orientation == Assembly::HORIZONTAL ?
              horizontal_constructions : vertical_constructions
          malformed!('coverage does not have a matching construction') unless index < constructions.length

          constructions[index]
        end

        def base_size(glyph_id)
          return 0 unless file.respond_to?(:horizontal_metrics)

          file.horizontal_metrics.for(glyph_id).advance_width
        end

        def part_for(variant)
          {
            glyph_id: variant.glyph_id,
            position: { x: 0, y: 0 },
            full_advance: variant.advance_measurement,
            start_connector: nil,
            end_connector: nil,
            extender: false,
          }
        end
      end
    end
  end
end
