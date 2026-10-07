# frozen_string_literal: true

require_relative 'record'
require_relative 'value'

module TTFunk
  class Table
    class Math < Table
      # One glyph in a glyph assembly.
      Part = Struct.new(
        :glyph_id, :extender, :start_connector, :end_connector,
        :full_advance, keyword_init: true
      )

      # A repeatable glyph assembly from the MATH variants table.
      class Assembly < Record
        HORIZONTAL = :horizontal
        VERTICAL = :vertical
        MAX_REPEAT_COUNT = 0xffff

        attr_reader :italics_correction
        attr_reader :parts
        attr_reader :orientation

        def initialize(file, table_offset, root_start = table_offset,
                       root_end = nil, orientation = HORIZONTAL)
          @orientation = orientation
          super(file, table_offset, root_start, root_end)
        end

        def natural_size
          parts.sum(&:full_advance)
        end

        def assemble(target, ppem = nil, min_connector_overlap = 0)
          validate_target!(target)
          validate_parts!

          repeat_count, overlaps =
            find_repeat_count_and_overlaps(target, min_connector_overlap)
          expanded = expand_parts(repeat_count)

          positions = positions_for(expanded, overlaps)
          result(target, expanded, positions, overlaps, repeat_count, ppem)
        end

        private

        def parse!
          @italics_correction = read_value_record(table_offset, 'assembly italics correction')
          count = read_uint16
          @parts = Array.new(count) { parse_part }
        end

        def parse_part
          glyph_id, flags, start_connector, end_connector, full_advance =
            read(10, 'nnnnn').each_with_index.map { |value, index|
              [2, 3].include?(index) ? to_signed(value) : value
            }

          Part.new(
            glyph_id: glyph_id,
            extender: (flags & 1) == 1,
            start_connector: start_connector,
            end_connector: end_connector,
            full_advance: full_advance,
          )
        end

        def validate_target!(target)
          unless target.is_a?(Integer) && target.positive?
            raise ArgumentError, 'MATH assembly target size must be a positive integer'
          end
        end

        def validate_parts!
          malformed!('glyph assembly has no parts') if parts.empty?

          parts.each do |part|
            if part.start_connector.negative? || part.end_connector.negative?
              malformed!('glyph connector length is negative')
            end

            if part.full_advance <= 0
              malformed!('glyph part full advance must be positive')
            end

            if part.start_connector > part.full_advance ||
               part.end_connector > part.full_advance
              malformed!('glyph connector length exceeds part advance')
            end
          end
        end

        def find_repeat_count_and_overlaps(target, min_connector_overlap)
          first_repeat_count = parts.any?(&:extender) ? 1 : 0

          first_repeat_count.upto(MAX_REPEAT_COUNT) do |repeat_count|
            expanded = expand_parts(repeat_count)
            minimum, maximum = size_bounds(expanded, min_connector_overlap)
            next unless target.between?(minimum, maximum)

            return [
              repeat_count,
              overlaps_for(expanded, target, minimum, min_connector_overlap)
            ]
          end

          raise Error, "MATH assembly cannot reach target size #{target}"
        end

        def size_bounds(expanded_parts, min_connector_overlap)
          bounds = overlap_bounds(expanded_parts, min_connector_overlap)
          total_advance = expanded_parts.sum(&:full_advance)
          minimum = total_advance - bounds.sum(&:last)
          maximum = total_advance - bounds.sum(&:first)
          [minimum, maximum]
        end

        def minimum_overlap_for(left, right, global_minimum)
          [
            global_minimum,
            left.end_connector,
            right.start_connector,
          ].max
        end

        def maximum_overlap_for(left, right)
          [left.full_advance, right.full_advance].min
        end

        def overlap_bounds(expanded_parts, global_minimum)
          seams(expanded_parts).map do |left, right|
            minimum = minimum_overlap_for(left, right, global_minimum)
            maximum = maximum_overlap_for(left, right)

            if minimum > maximum
              malformed!('required glyph connector overlap exceeds a part advance')
            end

            [minimum, maximum]
          end
        end

        def overlaps_for(expanded_parts, target, _minimum, min_connector_overlap)
          bounds = overlap_bounds(expanded_parts, min_connector_overlap)
          overlaps = bounds.map(&:first)
          remaining = expanded_parts.sum(&:full_advance) - target - overlaps.sum

          return overlaps if remaining.zero?

          bounds.each_index do |index|
            available = bounds[index].last - overlaps[index]
            adjustment = [remaining, available].min
            overlaps[index] += adjustment
            remaining -= adjustment
            break if remaining.zero?
          end

          malformed!('glyph connector overlap allocation failed') unless remaining.zero?

          overlaps
        end

        def expand_parts(repeat_count)
          parts.flat_map do |part|
            part.extender ? Array.new(repeat_count, part) : [part]
          end
        end

        def seams(expanded_parts)
          expanded_parts.each_cons(2).to_a
        end

        def positions_for(expanded_parts, overlaps)
          position = 0

          expanded_parts.each_with_index.map do |part, index|
            current = position
            position += part.full_advance - (overlaps[index] || 0)
            { part: part, position: current }
          end
        end

        def result(target, expanded_parts, positioned, overlaps, repeat_count, ppem)
          part_results =
            positioned.map do |entry|
              position =
                if orientation == HORIZONTAL
                  { x: entry[:position], y: 0 }
                else
                  { x: 0, y: entry[:position] }
                end

              {
                glyph_id: entry[:part].glyph_id,
                position: position,
                full_advance: entry[:part].full_advance,
                start_connector: entry[:part].start_connector,
                end_connector: entry[:part].end_connector,
                extender: entry[:part].extender,
              }
            end

          {
            glyphs: part_results.map { |part| part[:glyph_id] },
            parts: part_results,
            overlaps: overlaps,
            assembly: true,
            repeat_count: repeat_count,
            size: target,
            natural_size: expanded_parts.sum(&:full_advance),
            orientation: orientation,
            italic_correction: italics_correction&.value_at(ppem),
          }
        end
      end
    end
  end
end
