# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # OpenType MATH table.
    class OpenTypeMath < Table
      TAG = 'MATH'

      class ParseError < TTFunk::Error; end
      class SelectionError < TTFunk::Error; end

      MeasuredValue = Struct.new(:value, :device, keyword_init: true) do
        def at(ppem = nil)
          value + (device ? device.adjustment(ppem) : 0)
        end
      end

      Variant = Struct.new(:glyph_id, :advance_measurement, keyword_init: true)

      Part = Struct.new(
        :glyph_id,
        :start_connector_length,
        :end_connector_length,
        :full_advance_length,
        :extender,
        keyword_init: true
      )

      Assembly = Struct.new(
        :italic_correction,
        :parts,
        :seam_limits,
        :min_size,
        :max_size,
        :min_connector_overlap,
        :direction,
        keyword_init: true
      )
      Construction = Struct.new(:assembly, :variants, keyword_init: true)

      PartPosition = Struct.new(
        :glyph_id, :position, :overlap_after, keyword_init: true
      ) do
        def x
          position
        end

        def y
          position
        end
      end

      Selection = Struct.new(
        :glyph_ids, :positions, :size, :direction, :variant, :assembly,
        keyword_init: true
      ) do
        def variant?
          !variant.nil?
        end

        def assembly?
          !assembly.nil?
        end
      end

      CONSTANT_NAMES = %i[
        script_percent_scale_down
        script_script_percent_scale_down
        delimited_sub_form_min_height
        display_operator_min_height
        math_leading
        axis_height
        accent_base_height
        flattened_accent_base_height
        subscript_shift_down
        subscript_top_max
        subscript_baseline_drop_min
        superscript_shift_up
        superscript_shift_up_cramped
        superscript_bottom_min
        superscript_baseline_drop_max
        sub_superscript_gap_min
        superscript_bottom_max_with_subscript
        space_after_script
        upper_limit_gap_min
        upper_limit_baseline_rise_min
        lower_limit_gap_min
        lower_limit_baseline_drop_min
        stack_top_shift_up
        stack_top_display_style_shift_up
        stack_bottom_shift_down
        stack_bottom_display_style_shift_down
        stack_gap_min
        stack_display_style_gap_min
        stretch_stack_top_shift_up
        stretch_stack_bottom_shift_down
        stretch_stack_gap_above_min
        stretch_stack_gap_below_min
        fraction_numerator_shift_up
        fraction_numerator_display_style_shift_up
        fraction_denominator_shift_down
        fraction_denominator_display_style_shift_down
        fraction_numerator_gap_min
        fraction_num_display_style_gap_min
        fraction_rule_thickness
        fraction_denominator_gap_min
        fraction_denom_display_style_gap_min
        skewed_fraction_horizontal_gap
        skewed_fraction_vertical_gap
        overbar_vertical_gap
        overbar_rule_thickness
        overbar_extra_ascender
        underbar_vertical_gap
        underbar_rule_thickness
        underbar_extra_descender
        radical_vertical_gap
        radical_display_style_vertical_gap
        radical_rule_thickness
        radical_extra_ascender
        radical_kern_before_degree
        radical_kern_after_degree
        radical_degree_bottom_raise_percent
      ].freeze

      SCALAR_CONSTANTS = {
        script_percent_scale_down: :signed,
        script_script_percent_scale_down: :signed,
        delimited_sub_form_min_height: :unsigned,
        display_operator_min_height: :unsigned,
        radical_degree_bottom_raise_percent: :unsigned,
      }.freeze

      attr_reader :major_version, :minor_version
      attr_reader :constants
      attr_reader :italic_corrections
      attr_reader :top_accent_attachments
      attr_reader :horizontal_constructions
      attr_reader :vertical_constructions

      def constant(name, ppem = nil)
        name = normalize_constant_name(name)
        unless CONSTANT_NAMES.include?(name)
          raise ArgumentError, "unknown MATH constant #{name.inspect}"
        end

        measured = @constant_values.fetch(name)
        SCALAR_CONSTANTS.key?(name) ? measured.value : measured.at(ppem)
      end

      def italic_correction(glyph_id, ppem = nil)
        @italic_corrections[glyph_id]&.at(ppem)
      end
      alias italic_correction_for italic_correction

      def top_accent_attachment(glyph_id, ppem = nil)
        @top_accent_attachments[glyph_id]&.at(ppem)
      end
      alias top_accent_attachment_for top_accent_attachment

      def horizontal_construction_for(glyph_id)
        @horizontal_constructions[glyph_id]
      end

      def vertical_construction_for(glyph_id)
        @vertical_constructions[glyph_id]
      end

      def select_horizontal_variant(glyph_id, target_size)
        select_variant(:horizontal, glyph_id, target_size)
      end
      alias horizontal_variant_for select_horizontal_variant
      alias horizontal_variant select_horizontal_variant

      def select_vertical_variant(glyph_id, target_size)
        select_variant(:vertical, glyph_id, target_size)
      end
      alias vertical_variant_for select_vertical_variant
      alias vertical_variant select_vertical_variant

      def tag
        TAG
      end

      private

      def normalize_constant_name(name)
        name.to_s
          .gsub(/(?<=[a-z0-9])(?=[A-Z])/, '_')
          .downcase
          .to_sym
      end

      def parse!
        root = Section.new(io, offset, length)
        @major_version, @minor_version = root.read_version
        constants_offset, glyph_info_offset, variants_offset = root.read_offsets(3)

        @constants = {}
        @constant_values = {}
        parse_constants(root, constants_offset) if constants_offset.nonzero?

        @italic_corrections = {}
        @top_accent_attachments = {}
        parse_glyph_info(root, glyph_info_offset) if glyph_info_offset.nonzero?

        @horizontal_constructions = {}
        @vertical_constructions = {}
        parse_variants(root, variants_offset) if variants_offset.nonzero?
      end

      def parse_constants(root, table_offset)
        section = root.child(table_offset)
        CONSTANT_NAMES.each do |name|
          measured = parse_constant(section, name)
          @constants[name] = measured
          @constant_values[name] = measured
        end
      end

      def parse_constant(section, name)
        scalar_type = SCALAR_CONSTANTS[name]
        if scalar_type
          value = scalar_type == :signed ? section.read_signed : section.read_unsigned
          MeasuredValue.new(value: value, device: nil)
        else
          section.read_measured_value(section)
        end
      end

      def parse_glyph_info(root, table_offset)
        info = root.child(table_offset)
        italics_offset, accents_offset, _extended, _kerns = info.read_offsets(4)

        parse_measured_glyph_list(info, italics_offset)
          .each { |glyph_id, value| @italic_corrections[glyph_id] = value }
        parse_measured_glyph_list(info, accents_offset)
          .each { |glyph_id, value| @top_accent_attachments[glyph_id] = value }
      end

      def parse_measured_glyph_list(info, table_offset)
        return {} if table_offset.zero?

        list = info.child(table_offset)
        coverage_offset = list.read_offset
        count = list.read_unsigned
        glyph_ids = read_coverage(list, coverage_offset)
        validate_count(glyph_ids, count, 'coverage')

        glyph_ids.map do |glyph_id|
          [glyph_id, list.read_measured_value(list)]
        end.to_h
      end

      def parse_variants(root, table_offset)
        variants = root.child(table_offset)
        min_overlap = variants.read_unsigned
        vertical_coverage_offset, horizontal_coverage_offset = variants.read_offsets(2)
        vertical_count, horizontal_count = variants.read_unsigneds(2)
        vertical_offsets = variants.read_offsets(vertical_count)
        horizontal_offsets = variants.read_offsets(horizontal_count)

        vertical_glyphs = read_coverage(variants, vertical_coverage_offset)
        horizontal_glyphs = read_coverage(variants, horizontal_coverage_offset)
        validate_count(vertical_glyphs, vertical_count, 'vertical coverage')
        validate_count(horizontal_glyphs, horizontal_count, 'horizontal coverage')

        parse_construction_map(
          variants, vertical_glyphs, vertical_offsets, min_overlap, :vertical
        ).each { |glyph_id, construction| @vertical_constructions[glyph_id] = construction }
        parse_construction_map(
          variants, horizontal_glyphs, horizontal_offsets, min_overlap, :horizontal
        ).each { |glyph_id, construction| @horizontal_constructions[glyph_id] = construction }
      end

      def parse_construction_map(variants, glyphs, offsets, min_overlap, direction)
        glyphs.zip(offsets).filter_map do |glyph_id, construction_offset|
          next if construction_offset.zero?

          [glyph_id, parse_construction(variants, construction_offset, min_overlap, direction)]
        end.to_h
      end

      def parse_construction(variants, table_offset, min_overlap, direction)
        construction_section = variants.child(table_offset)
        assembly_offset, variant_count = construction_section.read_offset_and_count
        assembly = if assembly_offset.zero?
          nil
        else
          parse_assembly(construction_section, assembly_offset, min_overlap)
        end

        variant_records = variant_count.times.map do
          glyph_id, measurement = construction_section.read_unsigneds(2)
          Variant.new(glyph_id: glyph_id, advance_measurement: measurement)
        end

        construction = Construction.new(assembly: assembly, variants: variant_records)
        augment_assembly!(construction, min_overlap, direction)
        construction
      end

      def parse_assembly(construction_section, table_offset, min_overlap)
        assembly_section = construction_section.child(table_offset)
        italic_correction = assembly_section.read_measured_value(assembly_section)
        part_count = assembly_section.read_unsigned
        parts = part_count.times.map do
          glyph_id, start_connector, end_connector, full_advance, flags =
            assembly_section.read_unsigneds(5)
          Part.new(
            glyph_id: glyph_id,
            start_connector_length: start_connector,
            end_connector_length: end_connector,
            full_advance_length: full_advance,
            extender: flags.allbits?(0x1),
          )
        end
        Assembly.new(
          italic_correction: italic_correction,
          parts: parts,
          min_connector_overlap: min_overlap,
        )
      end

      def augment_assembly!(construction, min_overlap, direction)
        assembly = construction.assembly
        return unless assembly

        assembly.parts.each { |part| validate_part!(part, min_overlap) }
        assembly.seam_limits = seam_limits(assembly.parts, min_overlap)
        assembly.min_size = assembly_size(assembly.parts, assembly.seam_limits.map(&:last))
        assembly.max_size = assembly_size(assembly.parts, assembly.seam_limits.map(&:first))
        assembly.direction = direction
      end

      def validate_part!(part, _min_overlap)
        if part.full_advance_length.zero?
          raise ParseError, "MATH part #{part.glyph_id} has zero full advance"
        end
      end

      def seam_limits(parts, min_overlap)
        parts.each_cons(2).map do |left, right|
          minimum = [
            min_overlap,
            left.end_connector_length,
            right.start_connector_length,
          ].min
          maximum = [
            left.end_connector_length,
            right.start_connector_length,
            left.full_advance_length,
            right.full_advance_length,
          ].min
          if maximum < min_overlap
            raise ParseError, 'MATH assembly has no legal connector overlap'
          end

          [[min_overlap, left.end_connector_length, right.start_connector_length].min, maximum]
        end
      end

      def assembly_size(parts, overlaps)
        parts.sum(&:full_advance_length) - overlaps.sum
      end

      def validate_count(glyphs, count, label)
        if glyphs.length != count
          raise ParseError, "MATH #{label} count does not match record count"
        end
      end

      def read_coverage(section, offset)
        return [] if offset.zero?

        Coverage.read(section, offset)
      end

      def select_variant(direction, glyph_id, target_size)
        target = Integer(target_size)
        if target <= 0
          raise ArgumentError, 'MATH target size must be a positive number'
        end

        construction =
          if direction == :horizontal
            @horizontal_constructions[glyph_id]
          else
            @vertical_constructions[glyph_id]
          end

        unless construction
          raise SelectionError, "MATH has no #{direction} construction for glyph #{glyph_id}"
        end

        variant = construction.variants.find { |item| item.advance_measurement >= target }
        return variant_selection(direction, variant) if variant

        assembly_selection(direction, construction.assembly, target)
      end

      def variant_selection(direction, variant)
        position = PartPosition.new(
          glyph_id: variant.glyph_id, position: 0, overlap_after: nil
        )
        Selection.new(
          glyph_ids: [variant.glyph_id],
          positions: [position],
          size: variant.advance_measurement,
          direction: direction,
          variant: variant,
          assembly: nil,
        )
      end

      def assembly_selection(direction, assembly, target)
        unless assembly
          raise SelectionError, "no MATH variant or assembly reaches size #{target}"
        end

        if target < assembly.min_size
          raise SelectionError, "MATH assembly cannot reach size #{target}"
        end

        parts = expanded_parts(assembly, target)
        limits = seam_limits(parts, assembly.min_connector_overlap)
        overlaps = overlaps_for_size(parts, limits, target)
        positions = positions_for_parts(parts, overlaps)
        final_size = parts.last.full_advance_length + positions.last.position

        if final_size != target
          raise SelectionError, "MATH assembly cannot reach exact size #{target}"
        end

        selected_assembly = Assembly.new(
          italic_correction: assembly.italic_correction,
          parts: parts,
          seam_limits: limits,
          min_size: target,
          max_size: target,
          min_connector_overlap: assembly.min_connector_overlap,
          direction: direction,
        )
        Selection.new(
          glyph_ids: parts.map(&:glyph_id),
          positions: positions,
          size: final_size,
          direction: direction,
          variant: nil,
          assembly: selected_assembly,
        )
      end

      def expanded_parts(assembly, target)
        return assembly.parts if target <= assembly.max_size

        counts = extender_counts(assembly, target)
        assembly.parts.flat_map do |part|
          copies = counts.fetch(part.object_id, 0)
          [part] + Array.new(copies) { part.dup }
        end
      end

      def extender_counts(assembly, target)
        required_gain = target - assembly.min_size
        parts = assembly.parts
        min_overlap = assembly.min_connector_overlap
        base_slack = assembly.max_size - assembly.min_size
        extenders = parts.each_with_index.filter_map do |part, index|
          next unless part.extender

          seam_cap = [
            part.start_connector_length,
            part.end_connector_length,
            part.full_advance_length,
          ].min
          minimum_growth = part.full_advance_length - seam_cap
          maximum_growth = part.full_advance_length - min_overlap
          next unless minimum_growth >= 0 && maximum_growth.positive?

          {
            part: part,
            index: index,
            key: part.object_id,
            min_growth: minimum_growth,
            max_growth: maximum_growth,
          }
        end

        choose_extender_counts(extenders, required_gain, base_slack)
      end

      def choose_extender_counts(extenders, required_gain, base_slack)
        if extenders.empty?
          raise SelectionError, 'MATH assembly cannot reach requested size without extenders'
        end

        zero_growth_extenders, positive_growth_extenders =
          extenders.partition { |extender| extender[:min_growth].zero? }
        best_zero_growth_extender =
          zero_growth_extenders.max_by { |extender| extender[:max_growth] }

        states = Array.new(required_gain + 1)
        states[0] = [{ max_gain: 0, copies: 0, counts: {} }]

        positive_growth_extenders.each do |extender|
          min_growth = extender[:min_growth]
          min_growth.upto(required_gain) do |gain|
            Array(states[gain - min_growth]).each do |prior_state|
              candidate = candidate_extender_state(prior_state, extender, gain)
              add_state(states, gain, candidate)
            end
          end
        end

        best_state = nil
        0.upto(required_gain) do |gain|
          Array(states[gain]).flatten.each do |candidate|
            state = state_with_zero_growth_extender(
              candidate, best_zero_growth_extender, required_gain, base_slack
            )
            next unless state

            if best_state.nil? || state[:copies] < best_state[:copies]
              best_state = state
            end
          end
        end

        unless best_state
          raise SelectionError, "MATH assembly cannot reach requested size"
        end

        best_state[:counts]
      end

      def state_with_zero_growth_extender(
        candidate, extender, required_gain, base_slack
      )
        maximum_gain = candidate[:max_gain] + base_slack
        return candidate if maximum_gain >= required_gain
        return nil unless extender

        deficit = required_gain - maximum_gain
        copies = (deficit.to_f / extender[:max_growth]).ceil
        state = candidate.dup
        state[:copies] += copies
        state[:counts] = candidate[:counts].dup
        state[:counts][extender[:key]] =
          state[:counts].fetch(extender[:key], 0) + copies
        state
      end

      def candidate_extender_state(previous, extender, gain)
        counts = previous[:counts].dup
        counts[extender[:key]] = counts.fetch(extender[:key], 0) + 1
        {
          max_gain: previous[:max_gain] + extender[:max_growth],
          copies: previous[:copies] + 1,
          counts: counts,
        }
      end

      def add_state(states, gain, candidate)
        current_states = Array(states[gain])
        return if current_states.any? do |current|
          current[:max_gain] >= candidate[:max_gain] &&
            current[:copies] <= candidate[:copies]
        end

        current_states.reject! do |current|
          candidate[:max_gain] >= current[:max_gain] &&
            candidate[:copies] <= current[:copies]
        end
        states[gain] = current_states.push(candidate)
      end

      def overlaps_for_size(parts, limits, target)
        overlaps = limits.map(&:first)
        required_overlap = parts.sum(&:full_advance_length) - target
        extra = required_overlap - overlaps.sum
        return overlaps if extra.zero?
        raise SelectionError, 'MATH assembly cannot reach requested size' if extra.negative?

        distribute_overlap(overlaps, limits, extra)
        correct_size = overlaps.sum == required_overlap
        all_legal = overlaps.each_with_index.all? do |overlap, index|
          (limits[index][0]..limits[index][1]).include?(overlap)
        end
        unless correct_size && all_legal
          raise SelectionError, 'MATH assembly cannot reach requested size'
        end

        overlaps
      end

      def distribute_overlap(overlaps, limits, extra)
        remaining = extra
        while remaining.positive?
          indexes = overlaps.each_index.select do |index|
            overlaps[index] < limits[index][1]
          end
          raise SelectionError, 'MATH assembly cannot reach requested size' if indexes.empty?

          increment = [remaining.fdiv(indexes.length).floor, 1].max
          indexes.each do |index|
            available = limits[index][1] - overlaps[index]
            applied = [increment, available, remaining].min
            overlaps[index] += applied
            remaining -= applied
            break if remaining.zero?
          end
        end
      end

      def positions_for_parts(parts, overlaps)
        position = 0
        parts.each_with_index.map do |part, index|
          current_position = position
          overlap_after = overlaps.fetch(index, 0)
          position += part.full_advance_length - overlap_after
          PartPosition.new(
            glyph_id: part.glyph_id,
            position: current_position,
            overlap_after: overlap_after,
          )
        end
      end

      class Section
        def initialize(io, start, length)
          @io = StringIO.new(io.string.b)
          @start = start
          @length = length
          @end = start + length
          @io.pos = start
        end

        def read_version
          [read_unsigned, read_unsigned]
        end

        def read_signed
          value = read_unsigned
          value >= 0x8000 ? -((value ^ 0xFFFF) + 1) : value
        end

        def read_unsigned
          read_bytes(2).unpack1('n')
        end

        def read_unsigneds(count)
          Array.new(count) { read_unsigned }
        end

        def read_offset
          value = read_unsigned
          validate_offset(value)
          value
        end

        def read_offsets(count)
          Array.new(count) { read_offset }
        end

        def read_offset_and_count
          [read_offset, read_unsigned]
        end

        def read_measured_value(parent)
          value = read_signed
          device_offset = read_offset
          device = device_offset.zero? ? nil : Device.read(parent, device_offset)
          MeasuredValue.new(value: value, device: device)
        end

        def child(offset)
          absolute_offset = @start + offset
          unless absolute_offset >= @start && absolute_offset < @end
            raise ParseError, "MATH table offset #{offset} is out of bounds"
          end

          Section.new(@io, absolute_offset, @end - absolute_offset)
        end

        private

        def read_bytes(length)
          if @io.pos + length > @end
            raise ParseError, 'attempted to read past the end of MATH table'
          end

          @io.read(length)
        end

        def validate_offset(offset)
          return if offset.zero?
          return if @start + offset < @end

          raise ParseError, "MATH table offset #{offset} is out of bounds"
        end
      end

      class Coverage
        def self.read(section, offset)
          new(section.child(offset)).to_a
        end

        def initialize(section)
          @section = section
        end

        def to_a
          format = @section.read_unsigned
          case format
          when 1
            count = @section.read_unsigned
            @section.read_unsigneds(count)
          when 2
            count = @section.read_unsigned
            expected_coverage_index = 0
            count.times.flat_map do
              start_glyph, end_glyph, start_coverage_index = @section.read_unsigneds(3)
              if start_glyph > end_glyph
                raise ParseError, 'MATH coverage range starts after it ends'
              end
              unless start_coverage_index == expected_coverage_index
                raise ParseError, 'MATH coverage range indices are not contiguous'
              end

              expected_coverage_index += end_glyph - start_glyph + 1
              (start_glyph..end_glyph).to_a
            end
          else
            raise ParseError, "unsupported MATH coverage format #{format}"
          end
        end
      end

      class Device
        attr_reader :start_size, :end_size, :delta_format, :deltas

        def self.read(section, offset)
          new(section.child(offset))
        end

        def initialize(section)
          @start_size = section.read_unsigned
          @end_size = section.read_unsigned
          @delta_format = section.read_unsigned
          unless [1, 2, 3].include?(@delta_format)
            raise ParseError, "unsupported MATH device delta format #{@delta_format}"
          end
          if @start_size > @end_size
            raise ParseError, 'MATH device start size is after end size'
          end

          count = @end_size - @start_size + 1
          bit_width = @delta_format * 2
          word_count = ((count * bit_width) / 16.0).ceil
          words = Array.new(word_count) { section.read_unsigned }
          bits = Array.new(words.length * 16) do |index|
            word_index = index / 16
            bit_index = 15 - (index % 16)
            (words[word_index] >> bit_index) & 1
          end
          @deltas = Array.new(count) do |index|
            bit_offset = index * bit_width
            value = bits[bit_offset, bit_width].reduce(0) { |sum, bit| (sum << 1) | bit }
            sign_bit = 1 << (bit_width - 1)
            value >= sign_bit ? value - (sign_bit << 1) : value
          end
        end

        def adjustment(ppem)
          return 0 if ppem.nil?
          size = Integer(ppem)
          return 0 unless size.between?(@start_size, @end_size)

          @deltas[size - @start_size]
        end
      end
    end
  end
end
