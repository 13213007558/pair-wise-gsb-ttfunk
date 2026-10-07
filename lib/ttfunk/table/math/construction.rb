# frozen_string_literal: true

require_relative 'assembly'
require_relative 'record'

module TTFunk
  class Table
    class Math < Table
      Variant = Struct.new(
        :glyph_id, :advance_measurement,
        keyword_init: true
      )

      # Pre-built variants and an optional assembly for a source glyph.
      class Construction < Record
        attr_reader :variants
        attr_reader :assembly

        def initialize(file, table_offset, root_start, root_end, orientation)
          @orientation = orientation
          super(file, table_offset, root_start, root_end)
        end

        private

        def parse!
          variant_count = read_uint16
          @variants = Array.new(variant_count) do
            glyph_id, advance = read(4, 'n*')
            Variant.new(glyph_id: glyph_id, advance_measurement: advance)
          end

          assembly_offset = read_offset
          return if assembly_offset.zero?

          assembly_absolute =
            resolve_offset(table_offset, assembly_offset, 'glyph assembly')
          @assembly =
            Assembly.new(
              file, assembly_absolute, root_start, root_end, @orientation
            )
        end
      end
    end
  end
end
