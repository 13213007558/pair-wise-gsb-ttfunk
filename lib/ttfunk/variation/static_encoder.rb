# frozen_string_literal: true

module TTFunk
  module Variation
    class Instance
      # Assembles the binary static font from the instanced glyphs and the
      # untouched remainder of the source font's tables.
      class StaticEncoder
        # Tables rebuilt for the instance, in optimal layout order.
        REWRITTEN = ['glyf', 'loca', 'hmtx', 'hhea', 'maxp', 'head', 'cvt '].freeze

        def initialize(file, glyphs, removed_tables, cvt)
          @file = file
          @glyphs = glyphs
          @removed_tables = removed_tables
          @cvt = cvt
        end

        # @return [Hash]
        def encode
          tables = build_tables
          font = assemble(tables)

          {
            font: font,
            rewritten_tables: tables.keys.select { |tag|
              REWRITTEN.include?(tag)
            }.sort,
            copied_tables: tables.keys.reject { |tag|
              REWRITTEN.include?(tag)
            }.sort,
          }
        end

        private

        def build_tables
          tables = {}

          glyf = encode_glyf
          loca = Table::Loca.encode(glyf[:offsets])
          hmtx = encode_hmtx
          hhea = encode_hhea(hmtx)

          tables['glyf'] = glyf[:table]
          tables['loca'] = loca[:table]
          tables['hmtx'] = hmtx
          tables['hhea'] = hhea
          tables['maxp'] = encode_maxp
          tables['head'] = encode_head(loca)
          tables['cvt '] = @cvt if @cvt

          copy_passthrough(tables)
          tables
        end

        def encode_glyf
          table = +''
          offsets = []

          @glyphs.keys.sort.each do |glyph_id|
            offsets << table.length
            glyph = @glyphs[glyph_id]
            table << glyph.raw unless glyph.blank?
          end
          offsets << table.length

          { table: table, offsets: offsets }
        end

        # Emit a full long-form metric for every glyph. This is always valid
        # and avoids the run-length optimization (hhea numberOfHMetrics is
        # allowed to equal numGlyphs).
        def encode_hmtx
          @glyphs.keys.sort.map do |glyph_id|
            glyph = @glyphs[glyph_id]
            [glyph.advance_width, glyph.left_side_bearing]
          end.flatten.pack('n*')
        end

        def encode_hhea(hmtx)
          hhea = @file.horizontal_header
          metrics = hhea_metrics

          +''.b.tap do |table|
            table << [hhea.version].pack('N')
            table << [
              hhea.ascent, hhea.descent, hhea.line_gap,
              metrics[:advance_width_max],
              metrics[:min_left_side_bearing],
              metrics[:min_right_side_bearing],
              metrics[:x_max_extent],
              hhea.caret_slope_rise, hhea.caret_slope_run,
              hhea.caret_offset,
              0, 0, 0, 0,
              hhea.metric_data_format,
              @glyphs.length,
            ].pack('n*')
          end
        end

        def hhea_metrics
          advance_max = TTFunk::Max.new
          min_lsb = TTFunk::Min.new
          min_rsb = TTFunk::Min.new
          x_extent = TTFunk::Max.new

          @glyphs.each_value do |glyph|
            advance_max << glyph.advance_width
            min_lsb << glyph.left_side_bearing
            x_min, y_min, x_max, y_max = glyph.bounds
            next if x_min == x_max && y_min == y_max

            min_rsb <<
              glyph.advance_width - glyph.left_side_bearing -
              (x_max - x_min)
            x_extent << glyph.left_side_bearing + (x_max - x_min)
          end

          {
            advance_width_max: advance_max.value_or(0),
            min_left_side_bearing: min_lsb.value_or(0),
            min_right_side_bearing: min_rsb.value_or(0),
            x_max_extent: x_extent.value_or(0),
          }
        end

        def encode_maxp
          maxp = @file.maximum_profile
          table = +''
          table << [maxp.version, @glyphs.length].pack('Nn')

          if maxp.version == 0x10000
            table << maxp_statistics.map { |value| [value].pack('n') }.join
          end
          table
        end

        def maxp_statistics
          max_points = TTFunk::Max.new
          max_contours = TTFunk::Max.new
          max_components = TTFunk::Max.new
          max_instructions = TTFunk::Max.new
          component_points = TTFunk::Max.new
          component_contours = TTFunk::Max.new
          component_depth = TTFunk::Max.new

          @glyphs.each_value do |glyph|
            if glyph.compound?
              max_components << glyph.outline_size
              totals = component_totals(glyph)
              component_points << totals[:points]
              component_contours << totals[:contours]
              component_depth << totals[:depth]
            else
              max_points << glyph.outline_size
              max_contours << glyph.number_of_contours
              max_instructions << glyph.instruction_length
            end
          end

          [
            max_points.value_or(0),
            max_contours.value_or(0),
            component_points.value_or(0),
            component_contours.value_or(0),
            @file.maximum_profile.max_zones,
            @file.maximum_profile.max_twilight_points,
            @file.maximum_profile.max_storage,
            @file.maximum_profile.max_function_defs,
            @file.maximum_profile.max_instruction_defs,
            @file.maximum_profile.max_stack_elements,
            max_instructions.value_or(0),
            max_components.value_or(0),
            component_depth.value_or(0),
          ]
        end

        def component_totals(glyph, depth = 1)
          points = TTFunk::Sum.new
          contours = TTFunk::Sum.new
          max_depth = TTFunk::Max.new(depth)

          glyph.component_ids.each do |component_id|
            child = @glyphs[component_id]
            if child&.compound?
              totals = component_totals(child, depth + 1)
              points << totals[:points]
              contours << totals[:contours]
              max_depth << totals[:depth].value_or(depth + 1)
            elsif child
              points << child.outline_size
              contours << child.number_of_contours
            end
          end

          { points: points, contours: contours, depth: max_depth }
        end

        def encode_head(loca)
          head = @file.header
          bounds = global_bounds

          EncodedString.new do |table|
            table << [head.version, head.font_revision].pack('N2')
            table << [0].pack('N')
            table << [
              head.magic_number, head.flags, head.units_per_em,
              head.created, head.modified,
              *bounds,
              head.mac_style, head.lowest_rec_ppem,
              head.font_direction_hint,
              loca[:type] || 0,
              head.glyph_data_format,
            ].pack('Nn2q>2n*')
          end
        end

        def global_bounds
          x_min = TTFunk::Min.new
          y_min = TTFunk::Min.new
          x_max = TTFunk::Max.new
          y_max = TTFunk::Max.new

          @glyphs.each_value do |glyph|
            bx_min, by_min, bx_max, by_max = glyph.bounds
            next if bx_min == bx_max && by_min == by_max

            x_min << bx_min
            y_min << by_min
            x_max << bx_max
            y_max << by_max
          end

          [x_min, y_min, x_max, y_max].map { |aggregate| aggregate.value_or(0) }
        end

        def copy_passthrough(tables)
          tags = @file.directory.tables.keys -
                 @removed_tables -
                 %w[glyf loca hmtx hhea maxp head cvt ]
          tags -= ['cvt '] if @cvt

          tags.each do |tag|
            info = @file.directory_info(tag)
            @file.contents.seek(info[:offset])
            tables[tag] = @file.contents.read(info[:length]).b
          end
        end

        def assemble(tables)
          count = tables.length
          search_range = (2**Math.log2(count).floor) * 16
          entry_selector = Integer(Math.log2(2**Math.log2(count).floor))
          range_shift = count * 16 - search_range
          range_shift = 0 if range_shift.negative?

          font = EncodedString.new
          font << [
            @file.directory.scaler_type,
            count, search_range, entry_selector, range_shift,
          ].pack('Nn*')

          layout_order = optimal_order(tables.keys)
          offsets = {}

          tables.keys.sort.each do |tag|
            font << [tag, checksum(tables[tag])].pack('A4N')
            font << Placeholder.new(offset_placeholder(tag), length: 4)
            font << [tables[tag].length].pack('N')
          end

          layout_order.each do |tag|
            font.resolve_placeholder(offset_placeholder(tag),
                                    [font.length].pack('N'))
            font << tables[tag]
            font.align!(4)
          end

          font = font.string
          write_checksum_adjustment(font, tables)
          font
        end

        # Patch the head table's checkSumAdjustment field so that the whole
        # font checksums to 0xB1B0AFBA.
        def write_checksum_adjustment(font, tables)
          head_offset = head_table_offset(font, tables)
          provisional = font.b
          provisional[head_offset + 8, 4] = [0].pack('N')
          adjustment = 0xB1B0AFBA - checksum(provisional)
          font[head_offset + 8, 4] = [adjustment & 0xFFFFFFFF].pack('N')
        end

        def head_table_offset(font, tables)
          count = tables.length
          index = tables.keys.sort.index('head')
          entry = font[12 + index * 16, 16]
          entry[8, 4].unpack1('N')
        end

        def optimal_order(tags)
          TTFEncoder::OPTIMAL_TABLE_ORDER.select { |tag|
            tags.include?(tag)
          } + (tags - TTFEncoder::OPTIMAL_TABLE_ORDER - ['DSIG']) +
            (tags.include?('DSIG') ? ['DSIG'] : [])
        end

        def offset_placeholder(tag)
          "offset_#{tag}".to_sym
        end

        def checksum(data)
          bytes = data.respond_to?(:unresolved_string) ?
                    data.unresolved_string : data
          padding = bytes.length % 4
          bytes += "\0" * (4 - padding) if padding.positive?
          bytes.unpack('N*').sum & 0xFFFF_FFFF
        end

      end
    end
  end
end
