# frozen_string_literal: true

require_relative 'glyph_value_table'
require_relative 'record'

module TTFunk
  class Table
    class Math < Table
      # Per-glyph MATH data.
      class GlyphInfo < Record
        attr_reader :italics_correction
        attr_reader :top_accent_attachment

        private

        def parse!
          italics_offset, top_accent_offset, _kern_offset, _extended_coverage_offset =
            read(8, 'n*')

          @italics_correction =
            child_record(ItalicsCorrection, table_offset, italics_offset,
                         'italics correction info')
          @top_accent_attachment =
            child_record(TopAccentAttachment, table_offset, top_accent_offset,
                         'top accent attachment')
        end
      end
    end
  end
end
