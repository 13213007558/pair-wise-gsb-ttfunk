# frozen_string_literal: true

require 'set'
require_relative '../encoded_string'
require_relative '../placeholder'
require_relative '../table/loca'

module TTFunk
  module Variation
    # Serializes a fully instantiated, variation-free TrueType font.
    #
    # All variation tables are dropped; glyf, loca, hmtx, hhea and head are
    # rebuilt from interpolated data while every remaining table is copied
    # verbatim.
    #
    # @api private
    class StaticFontEncoder
      TABLES_TO_DROP = %w[
        fvar avar gvar HVAR VVAR MVAR STAT cvar DSIG
      ].to_set.freeze

      def initialize(file, glyphs)
        @file = file
        @glyphs = glyphs
      end

      def encode
        tables = build_tables
        binary = assemble(tables)
        binary.string
      end

      private

      def build_tables
        @tables = copied_tables.merge!(
          'glyf' => glyf_data[:table],
          'loca' => loca_data[:table],
          'hmtx' => hmtx_data,
          'hhea' => hhea_data,
          'head' => encoded_head,
        )
        @tables
      end

      def copied_tables
        @file.directory.tables.each_with_object({}) do |(tag, info), tables|
          next if TABLES_TO_DROP.include?(tag)
          next if %w[glyf loca hmtx hhea head].include?(tag)

          tables[tag] = read_table(info)
        end
      end

      def read_table(info)
        io = @file.contents
        saved = io.pos
        io.pos = info[:offset]
        io.read(info[:length])
      ensure
        io.pos = saved
      end

      def glyf_data
        @glyf_data ||= begin
          table = +''.b
          offsets = []

          @glyphs.keys.sort.each do |glyph_id|
            offsets << table.length
            raw = @glyphs[glyph_id].raw
            next if raw.nil?

            table << raw
            # Glyph records must start on even offsets for the short loca
            # format. Loca.encode falls back to long offsets otherwise.
            table << "\0".b if table.length.odd?
          end

          offsets << table.length
          { table: table, offsets: offsets }
        end
      end

      def loca_data
        @loca_data ||= Table::Loca.encode(glyf_data[:offsets])
      end

      def hmtx_data
        @glyphs.keys.sort.map do |glyph_id|
          glyph = @glyphs[glyph_id]
          [glyph.advance_width, glyph.left_side_bearing].map { |value| value & 0xFFFF }
        end.flatten.pack('n*')
      end

      def hhea_data
        hhea = @file.horizontal_header
        values = calculate_hhea_values
        [hhea.version].pack('N') + values.pack('n*')
      end

      def calculate_hhea_values
        advance_width_max = 0
        min_left_side_bearing = nil
        min_right_side_bearing = nil
        x_max_extent = nil

        @glyphs.each_value do |glyph|
          advance_width_max = [advance_width_max, glyph.advance_width].max
          min_left_side_bearing = min_value(min_left_side_bearing, glyph.left_side_bearing)

          next unless glyph.bbox

          x_min, _y_min, x_max, _y_max = glyph.bbox
          width = x_max - x_min
          right_side_bearing =
            glyph.advance_width - glyph.left_side_bearing - width
          min_right_side_bearing = min_value(min_right_side_bearing, right_side_bearing)
          extent = glyph.left_side_bearing + x_max
          x_max_extent = [x_max_extent || extent, extent].max
        end

        ascent = signed_16(@file.horizontal_header.ascent)
        descent = signed_16(@file.horizontal_header.descent)
        line_gap = signed_16(@file.horizontal_header.line_gap)

        [
          ascent, descent, line_gap,
          advance_width_max,
          min_left_side_bearing || 0,
          min_right_side_bearing || 0,
          x_max_extent || 0,
          @file.horizontal_header.caret_slope_rise,
          @file.horizontal_header.caret_slope_run,
          @file.horizontal_header.caret_offset,
          0, 0, 0, 0,
          0, @glyphs.length,
        ]
      end

      def min_value(current, candidate)
        current.nil? || candidate < current ? candidate : current
      end

      def signed_16(value)
        value
      end

      def raw_head
        info = @file.directory_info('head')
        read_table(info)
      end

      def encoded_head
        EncodedString.new do |head|
          data = raw_head.dup
          data[8, 4] = "\0\0\0\0".b
          data[36, 8] = global_bbox.pack('n*')
          data[50, 2] = [loca_data[:type]].pack('n')

          head << data[0, 8]
          head << Placeholder.new(:checksum, length: 4)
          head << data[12..]
        end
      end

      def global_bbox
        bboxes = @glyphs.values.map(&:bbox).compact
        return [0, 0, 0, 0] if bboxes.empty?

        [
          bboxes.map(&:first).min,
          bboxes.map { |b| b[1] }.min,
          bboxes.map { |b| b[2] }.max,
          bboxes.map { |b| b[3] }.max,
        ].map { |value| value & 0xFFFF }
      end

      def assemble(tables)
        ordered_tags = tables.keys.sort
        search_range = (2**Math.log2(tables.length).floor) * 16
        entry_selector = Integer(Math.log2(2**Math.log2(tables.length).floor))
        range_shift = (tables.length * 16) - search_range
        range_shift = 0 if range_shift.negative?

        font = EncodedString.new
        font << [
          @file.directory.scaler_type, tables.length,
          search_range, entry_selector, range_shift,
        ].pack('Nn*')

        ordered_tags.each do |tag|
          font << [tag, checksum(tables[tag])].pack('A4N')
          font << Placeholder.new("offset_#{tag}".to_sym, length: 4)
          font << [tables[tag].length].pack('N')
        end

        order = preferred_order(ordered_tags)
        order.each do |tag|
          next unless tables.key?(tag)

          font.resolve_placeholder(
            "offset_#{tag}".to_sym, [font.length].pack('N')
          )
          font << tables[tag]
          font.align!(4)
        end

        sum = checksum(font.unresolved_string)
        adjustment = (0xB1B0AFBA - sum) & 0xFFFF_FFFF
        font.resolve_placeholder(:checksum, [adjustment].pack('N'))
        font
      end

      def preferred_order(tags)
        preferred = %w[
          head hhea maxp OS/2 hmtx LTSH VDMX hdmx cmap fpgm prep cvt loca glyf
          kern name post gasp PCLT
        ]
        preferred + (tags - preferred)
      end

      def checksum(data)
        data = data.respond_to?(:unresolved_string) ? data.unresolved_string : data
        padded =
          if (data.length % 4).positive?
            data + ("\0".b * (4 - (data.length % 4)))
          else
            data
          end
        padded.unpack('N*').sum & 0xFFFF_FFFF
      end
    end

  end
end
