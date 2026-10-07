# frozen_string_literal: true

require_relative 'coverage'
require_relative 'record'
require_relative 'value'

module TTFunk
  class Table
    class Math < Table
      # Shared parser for italics correction and top accent attachment tables.
      class GlyphValueTable < Record
        attr_reader :coverage
        attr_reader :entries

        def for_glyph(glyph_id, ppem = nil)
          index = coverage.index_for(glyph_id)
          return unless index

          entries.fetch(index).value_at(ppem)
        end

        private

        def parse!
          count = read_uint16
          coverage_offset = read_offset
          coverage_absolute =
            resolve_offset(table_offset, coverage_offset, coverage_name)
          @coverage = Coverage.new(file, coverage_absolute, root_start, root_end)
          malformed!("#{coverage_name} count does not match coverage") unless count == coverage.glyphs.length

          @entries = Array.new(count) do |index|
            record_base = io.pos
            read_value_record(record_base, "#{record_name} #{index}")
          end
        end

        def coverage_name
          self.class.name.split('::').last
        end

        def record_name
          coverage_name
        end
      end

      class ItalicsCorrection < GlyphValueTable
      end

      class TopAccentAttachment < GlyphValueTable
      end
    end
  end
end
