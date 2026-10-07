# frozen_string_literal: true

require_relative 'record'

module TTFunk
  class Table
    class Math < Table
      # A subset of the OpenType Coverage table formats used by MATH.
      class Coverage < Record
        attr_reader :format
        attr_reader :glyphs

        def index_for(glyph_id)
          case format
          when 1
            glyphs.index(glyph_id)
          when 2
            range = ranges.find do |range_start, range_end, _|
              glyph_id.between?(range_start, range_end)
            end

            return unless range

            range_start, _range_end, coverage_index = range
            index = coverage_index + (glyph_id - range_start)
            index
          end
        end

        private

        attr_reader :ranges

        def parse!
          @format = read_uint16

          case format
          when 1
            count = read_uint16
            @glyphs = Array.new(count) { read_uint16 }
          when 2
            count = read_uint16
            @ranges = Array.new(count) { read(6, 'n*') }
            @glyphs = build_range_glyphs
          else
            malformed!("unsupported coverage format #{format}")
          end
        end

        def build_range_glyphs
          ranges.each_with_object([]) do |(range_start, range_end, coverage_index), glyphs|
            malformed!('coverage range is reversed') if range_start > range_end

            (range_start..range_end).each do |glyph_id|
              glyphs[coverage_index + (glyph_id - range_start)] = glyph_id
            end
          end
        end
      end
    end
  end
end
