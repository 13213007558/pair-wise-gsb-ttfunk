# frozen_string_literal: true

require_relative 'record'
require_relative 'value'

module TTFunk
  class Table
    class Math < Table
      # Mathematical constants in a `MATH` table.
      class Constants < Record
        NAMES = %i[
          script_percent_scale_down
          script_script_percent_scale_down
          delimited_sub_formula_min_height
          display_operator_min_height
          math_leading
          axis_height
          flattened_accent_base_height
          subscript_shift_down
          subscript_top_max
          subscript_baseline_drop_min
          superscript_shift_up
          superscript_shift_up_cramped
          superscript_bottom_min
          superscript_baseline_drop_max
          sub_script_superscript_gap_min
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
          fraction_numerator_display_style_gap_min
          fraction_rule_thickness
          fraction_denominator_gap_min
          fraction_denominator_display_style_gap_min
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
          radical_degree_bottom_raised_percent_rise
        ].freeze

        VALUE_RECORD_RANGE = (2..53).freeze

        attr_reader :values

        def [](name, ppem = nil)
          value = values.fetch(name.to_sym) do
            raise ArgumentError, "unknown MATH constant #{name.inspect}"
          end

          value.respond_to?(:value_at) ? value.value_at(ppem) : value
        end

        def to_h(ppem = nil)
          values.transform_values do |value|
            value.respond_to?(:value_at) ? value.value_at(ppem) : value
          end
        end

        private

        def parse!
          @values = {}

          NAMES.each_with_index do |name, index|
            values[name] =
              if VALUE_RECORD_RANGE.include?(index)
                record_base = io.pos
                read_value_record(record_base, name.to_s)
              else
                read_int16
              end
          end
        end
      end
    end
  end
end
