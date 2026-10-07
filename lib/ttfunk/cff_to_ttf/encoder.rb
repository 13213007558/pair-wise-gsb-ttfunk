# frozen_string_literal: true

require_relative '../ttf_encoder'
require_relative '../table/simple'
require_relative '../table/loca'

module TTFunk
  module CffToTtf
    # Assembles a TrueType font from converted glyph outlines and the tables
    # of a CFF-based OpenType font.
    #
    # Glyph IDs are preserved one to one so character mapping (+cmap+) and
    # horizontal metrics (+hmtx+) carry over unchanged. CFF hints are not
    # translated: glyphs contain no instructions and no +cvt +, +fpgm+, or
    # +prep+ tables are produced, and the +maxp+ table (rewritten to version
    # 1.0 as required for TrueType outlines) declares zero instruction
    # resources accordingly.
    class Encoder < TTFEncoder
      # Tables copied verbatim from the original font. They don't depend on
      # the outline format and glyph IDs are unchanged.
      COPIED_TABLES = [
        'cmap', 'hmtx', 'name', 'OS/2', 'post',
        'kern', 'GDEF', 'GSUB', 'GPOS', 'gasp', 'VORG',
      ].freeze

      # Converted glyphs indexed by glyph ID.
      # @return [Array<TTFunk::CffToTtf::GlyphEncoder::EncodedGlyph>]
      attr_reader :glyphs

      # @param original [TTFunk::File]
      # @param glyphs [Array<TTFunk::CffToTtf::GlyphEncoder::EncodedGlyph>]
      def initialize(original, glyphs)
        super(original, nil)
        @glyphs = glyphs
      end

      private

      # TrueType outlines use the 0x00010000 scaler type, not 'OTTO'.
      def scaler_type
        0x0001_0000
      end

      def tables
        @tables ||= begin
          result = {
            'head' => head_table,
            'hhea' => hhea_table,
            'maxp' => maxp_table,
            'loca' => loca_table[:table],
            'glyf' => glyf_table[:table],
          }

          COPIED_TABLES.each do |tag|
            if original.directory.tables.key?(tag)
              result[tag] = TTFunk::Table::Simple.new(original, tag).raw
            end
          end

          result
        end
      end

      def glyf_table
        @glyf_table ||= begin
          table = +''.b
          offsets = []

          glyphs.each do |glyph|
            offsets << table.length
            table << glyph.raw
            # Keep offsets even so the short loca format can be used.
            table << "\0" if table.length.odd?
          end
          offsets << table.length

          { table: table, offsets: offsets }
        end
      end

      def loca_table
        @loca_table ||= TTFunk::Table::Loca.encode(glyf_table[:offsets])
      end

      def head_table
        head = original.header

        EncodedString.new do |table|
          table <<
            [head.version, head.font_revision].pack('N2') <<
            Placeholder.new(:checksum, length: 4) <<
            [
              head.magic_number,
              head.flags, head.units_per_em,
              head.created, head.modified,
              x_min, y_min, x_max, y_max,
              head.mac_style, head.lowest_rec_ppem, head.font_direction_hint,
              loca_table[:type] || 0, 0,
            ].pack('Nn2q>2s>4n5')
        end
      end

      def hhea_table
        hhea = original.horizontal_header

        [
          [hhea.version].pack('N'),
          [
            hhea.ascent, hhea.descent, hhea.line_gap,
            advance_width_max,
            min_left_side_bearing, min_right_side_bearing, x_max_extent,
            hhea.caret_slope_rise, hhea.caret_slope_run, hhea.caret_offset,
            0, 0, 0, 0,
            hhea.metric_data_format,
          ].pack('s>*'),
          [hhea.number_of_metrics].pack('n'),
        ].join
      end

      # TrueType outlines require a version 1.0 maxp table. No TrueType
      # instructions are emitted (CFF hints are not converted) so all
      # instruction-related maxima are zero.
      def maxp_table
        [
          0x0001_0000, glyphs.length,
          glyphs.map(&:number_of_points).max || 0,
          glyphs.map(&:number_of_contours).max || 0,
          0, # maxComponentPoints
          0, # maxComponentContours
          1, # maxZones
          0, # maxTwilightPoints
          0, # maxStorage
          0, # maxFunctionDefs
          0, # maxInstructionDefs
          0, # maxStackElements
          0, # maxSizeOfInstructions
          0, # maxComponentElements
          0, # maxComponentDepth
        ].pack('Nn*')
      end

      def x_min
        @x_min ||= glyphs.reject(&:empty?).map(&:x_min).min || 0
      end

      def y_min
        @y_min ||= glyphs.reject(&:empty?).map(&:y_min).min || 0
      end

      def x_max
        @x_max ||= glyphs.reject(&:empty?).map(&:x_max).max || 0
      end

      def y_max
        @y_max ||= glyphs.reject(&:empty?).map(&:y_max).max || 0
      end

      def advance_width_max
        @advance_width_max ||=
          horizontal_metrics.map(&:advance_width).max || 0
      end

      def min_left_side_bearing
        @min_left_side_bearing ||= outlined_glyph_metrics
          .map { |metric, _glyph| metric.left_side_bearing }
          .min || 0
      end

      def min_right_side_bearing
        @min_right_side_bearing ||= outlined_glyph_metrics
          .map { |metric, glyph|
            metric.advance_width - metric.left_side_bearing -
              (glyph.x_max - glyph.x_min)
          }
          .min || 0
      end

      def x_max_extent
        @x_max_extent ||= outlined_glyph_metrics
          .map { |metric, glyph| metric.left_side_bearing + (glyph.x_max - glyph.x_min) }
          .max || 0
      end

      # Pairs of horizontal metrics and converted glyphs for glyphs that have
      # outlines (empty glyphs are ignored for side bearing computation).
      def outlined_glyph_metrics
        @outlined_glyph_metrics ||= glyphs
          .each_with_index
          .reject { |glyph, _glyph_id| glyph.empty? }
          .map { |glyph, glyph_id| [horizontal_metrics[glyph_id], glyph] }
      end

      def horizontal_metrics
        @horizontal_metrics ||=
          glyphs.each_index.map { |glyph_id|
            original.horizontal_metrics.for(glyph_id)
          }
      end
    end
  end
end
