# frozen_string_literal: true

require 'set'

module TTFunk
  class Table
    class MathTable < Table
      # Geometry-only horizontal or vertical glyph stretch plan.
      #
      # Ties are resolved by choosing more repeats from the earlier extender
      # in the GlyphAssembly part-record order.
      class StretchPlan
        class NoStretchError < StandardError; end
        class NoAssemblyError < NoStretchError; end
        class UnreachableAdvanceError < NoStretchError; end

        Segment = Struct.new(
          :glyph_id, :position, :full_advance, :overlap_before,
          keyword_init: true
        )

        attr_reader :glyph_id, :target_advance, :actual_advance,
          :italic_correction, :segments

        def self.build(
          glyph_id, target_advance, direction, construction,
          min_connector_overlap, italic_corrections
        )
          new(
            glyph_id, target_advance, direction, construction,
            min_connector_overlap, italic_corrections
          ).build
        end

        attr_reader :direction, :construction, :min_connector_overlap,
          :italic_corrections

        def initialize(
          glyph_id, target_advance, direction, construction,
          min_connector_overlap, italic_corrections
        )
          @glyph_id = glyph_id
          @target_advance = target_advance
          @direction = direction
          @construction = construction
          @min_connector_overlap = min_connector_overlap
          @italic_corrections = italic_corrections
        end

        def build
          if target_advance.negative?
            raise ArgumentError, 'target advance must be non-negative'
          end
          unless %i[horizontal vertical].include?(direction)
            raise ArgumentError, "unsupported direction #{direction}"
          end

          variant = fitting_variant
          return variant_plan(variant) if variant

          unless construction&.assembly
            raise NoAssemblyError, no_assembly_message
          end

          assembly_plan
        end

        private

        def fitting_variant
          return unless construction

          construction.variants
            .each_with_index
            .select { |variant, _| variant.advance >= target_advance }
            .min_by { |variant, index| [variant.advance, index] }
            &.first
        end

        def variant_plan(variant)
          @actual_advance = variant.advance
          @italic_correction = italic_corrections.call(variant.glyph_id)
          @segments = [
            Segment.new(
              glyph_id: variant.glyph_id,
              position: 0,
              full_advance: variant.advance,
              overlap_before: 0,
            ),
          ]
          self
        end

        def no_assembly_message
          "glyph #{glyph_id} has no #{direction} glyph assembly"
        end

        def assembly_plan
          selected_parts = select_parts
          sequence = expand_parts(selected_parts)
          bounds = bounds_for(sequence)

          unless target_advance.between?(bounds[:minimum], bounds[:maximum])
            raise UnreachableAdvanceError,
              "#{direction} assembly for glyph #{glyph_id} can reach " \
                "#{bounds[:minimum]}..#{bounds[:maximum]} design units"
          end

          @actual_advance = target_advance
          @italic_correction = construction.assembly.italic_correction
          @segments = position_segments(sequence)
          self
        end

        def select_parts
          base_parts = construction.assembly.parts
          base = bounds_for(base_parts)

          if target_advance < base[:minimum]
            smallest_skipped_assembly(base_parts).map { |part| [part, 1] }
          else
            extra_counts = extra_multiplicities(base_parts, base)
            base_parts.each_with_index.map do |part, index|
              [part, extra_counts.fetch(index, 0) + 1]
            end
          end
        end

        def extra_multiplicities(parts, base)
          required_extra_length = target_advance - base[:maximum]
          return {} if required_extra_length <= 0

          extender_indices = parts.each_index.select do |index|
            parts[index].extender?
          end
          if extender_indices.empty?
            raise_unreachable
          end

          growth_rates = extender_indices.map do |index|
            parts[index].full_advance - min_connector_overlap
          end
          if growth_rates.all? { |rate| rate <= 0 }
            raise_unreachable
          end

          find_extra_allocation(
            parts, extender_indices, growth_rates, base
          )
        end

        def each_allocation(
          indices, count, position = 0, allocation = {}, &block
        )
          if position == indices.length
            yield allocation if count.zero?
            return
          end

          index = indices[position]
          count.downto(0) do |use|
            each_allocation(
              indices,
              count - use,
              position + 1,
              allocation.merge(index => use),
              &block
            )
          end
        end

        def find_extra_allocation(parts, extender_indices, growth_rates, base)
          maximum_growth = growth_rates.max
          first_count = [
            0,
            ((target_advance - base[:maximum]).to_f / maximum_growth).ceil,
          ].max
          last_count = (
            (target_advance - base[:minimum]) / maximum_growth
          ).floor

          first_count.upto(last_count) do |count|
            each_allocation(extender_indices, count) do |allocation|
              return allocation if feasible_allocation?(parts, allocation)
            end
          end
          raise_unreachable
        end

        def feasible_allocation?(parts, allocation)
          sequence = expand_parts(
            parts.each_with_index.map do |part, index|
              [part, allocation.fetch(index, 0) + 1]
            end,
          )
          bounds = bounds_for(sequence)
          target_advance.between?(bounds[:minimum], bounds[:maximum])
        end

        def smallest_skipped_assembly(parts)
          extender_indices = parts.each_index.select do |index|
            parts[index].extender?
          end

          (0..extender_indices.length).each do |count|
            extender_indices.combination(count).each do |indices|
              skipped = indices.to_set
              selected_parts = parts.each_with_index.reject do |_, index|
                skipped.include?(index)
              end.map(&:first)
              bounds = bounds_for(selected_parts)

              if target_advance.between?(bounds[:minimum], bounds[:maximum])
                return selected_parts
              end
            end
          end

          raise_unreachable
        end

        def expand_parts(selected_parts)
          selected_parts.flat_map { |part, count| Array.new(count, part) }
        end

        def bounds_for(parts)
          full_advance = parts.sum(&:full_advance)
          bounds = overlap_bounds(parts)

          {
            minimum: full_advance - bounds.sum { |bound| bound[:maximum] },
            maximum: full_advance - bounds.sum { |bound| bound[:minimum] },
          }
        end

        def overlap_bounds(parts)
          parts.each_cons(2).with_index.map do |(left, right), index|
            cap = [
              left.end_connector_length,
              right.start_connector_length,
            ].min
            if cap < min_connector_overlap
              raise UnreachableAdvanceError,
                "#{direction} assembly junction #{index} allows #{cap} " \
                  "overlap, less than minimum #{min_connector_overlap}"
            end

            { minimum: min_connector_overlap, maximum: cap }
          end
        end

        def raise_unreachable
          bounds = bounds_for(construction.assembly.parts)
          raise UnreachableAdvanceError,
            "#{direction} assembly for glyph #{glyph_id} can reach " \
              "#{bounds[:minimum]}..#{bounds[:maximum]} design units"
        end

        def position_segments(parts)
          full_advance = parts.sum(&:full_advance)
          bounds = overlap_bounds(parts)
          overlap_sum = full_advance - target_advance
          overlaps = balanced_overlaps(bounds, overlap_sum)
          if overlap_sum.negative?
            raise_unreachable
          end
          overlaps.each do |index, overlap|
            bound = bounds[index]
            unless overlap.between?(bound[:minimum], bound[:maximum])
              raise_unreachable
            end
          end

          position = 0
          parts.each_with_index.map do |part, index|
            segment_position = position
            overlap = index + 1 < parts.length ? overlaps[index] : 0
            position += part.full_advance - overlap
 
            Segment.new(
              glyph_id: part.glyph_id,
              position: segment_position,
              full_advance: part.full_advance,
              overlap_before: index.zero? ? 0 : overlaps[index - 1],
            )
          end
        end

        def balanced_overlaps(bounds, total)
          remaining = bounds.each_with_index.map do |bound, index|
            [index, bound.dup]
          end.to_h
          overlaps = {}
          left = total

          until remaining.empty?
            base = remaining.values.sum { |bound| bound[:minimum] }
            extra = left - base
            share = extra / remaining.length
            remainder = extra % remaining.length
            capped = false

            remaining.keys.each_with_index do |index, order|
              value = remaining[index][:minimum] + share
              value += 1 if order < remainder
              next unless value >= remaining[index][:maximum]

              overlaps[index] = remaining[index][:maximum]
              left -= overlaps[index]
              remaining.delete(index)
              capped = true
              break
            end

            next if capped

            remaining.keys.each_with_index do |index, order|
              value = remaining[index][:minimum] + share
              value += 1 if order < remainder
              overlaps[index] = value
            end
            remaining.clear
          end

          overlaps
        end
      end
    end
  end
end
