# frozen_string_literal: true

module TTFunk
  # Encodes a CFF-based OpenType font subset to its binary representation.
  class OTFEncoder < TTFEncoder
    # Optimal table order according to OpenType specification.
    OPTIMAL_TABLE_ORDER = ['head', 'hhea', 'maxp', 'OS/2', 'name', 'cmap', 'post', 'CFF '].freeze

    TRUE_TYPE_SCALER_TYPE = 0x00010000

    CONVERSION_OPTION_KEYS = [
      :cff_to_truetype,
      :cff_to_ttf,
      :convert_cff_to_truetype,
      :convert_cff_to_ttf,
    ].freeze

    TOLERANCE_OPTION_KEYS = [
      :cff_to_truetype_tolerance,
      :cff_to_ttf_tolerance,
      :truetype_outline_tolerance,
      :quadratic_tolerance,
      :tolerance,
    ].freeze

    private

    # CFF fonts don't maintain a glyf table, all glyph information is stored
    # in the charstrings index. Return an empty hash here to indicate a glyf
    # table should not be encoded.
    def glyf_table
      convert_to_true_type? ? super : @glyf_table ||= {}
    end

    # Since CFF fonts don't maintain a glyf table, they also don't maintain
    # a loca table. Return an empty hash here to indicate a loca table
    # shouldn't be encoded.
    def loca_table
      convert_to_true_type? ? super : @loca_table ||= {}
    end

    def base_table
      @base_table ||= TTFunk::Table::Simple.new(original, 'BASE').raw
    end

    def cff_table
      unless convert_to_true_type?
        @cff_table ||= original.cff.encode(subset)
      end
    end

    def vorg_table
      unless convert_to_true_type?
        @vorg_table ||= TTFunk::Table::Vorg.encode(original.vertical_origins)
      end
    end

    def tables
      @tables ||=
        if convert_to_true_type?
          super.reject { |tag| ['VORG', 'CFF '].include?(tag) }
        else
          super.merge(
            'BASE' => base_table,
            'VORG' => vorg_table,
            'CFF ' => cff_table,
          ).compact
        end
    end

    def optimal_table_order
      return super if convert_to_true_type?

      # DSIG is always last
      OPTIMAL_TABLE_ORDER +
        (tables.keys - ['DSIG'] - OPTIMAL_TABLE_ORDER) +
        ['DSIG']
    end

    def maxp_table
      return super unless convert_to_true_type?

      @maxp_table ||=
        TTFunk::Table::Maxp.encode_true_type(new_to_old_glyph, glyphs)
    end

    def cvt_table
      convert_to_true_type? ? nil : super
    end

    def fpgm_table
      convert_to_true_type? ? nil : super
    end

    def prep_table
      convert_to_true_type? ? nil : super
    end

    def glyphs
      convert_to_true_type? ? converted_glyphs : super
    end

    def scaler_type
      convert_to_true_type? ? TRUE_TYPE_SCALER_TYPE : super
    end

    def convert_to_true_type?
      options.values_at(*CONVERSION_OPTION_KEYS).compact.any? do |value|
        value == true || value.is_a?(Numeric)
      end ||
        (options.key?(:quadratic_tolerance) && options[:quadratic_tolerance] != false)
    end

    def quadratic_tolerance
      explicit = options.values_at(*TOLERANCE_OPTION_KEYS).compact.first
      conversion = options.values_at(*CONVERSION_OPTION_KEYS).compact.first
      tolerance = explicit || (conversion.is_a?(Numeric) ? conversion : nil)

      unless tolerance.is_a?(Numeric) && tolerance.positive?
        raise ArgumentError,
          'CFF to TrueType conversion requires a positive numeric tolerance in font units'
      end

      tolerance
    end

    def converted_glyphs
      @converted_glyphs ||=
        begin
          tolerance = quadratic_tolerance
          subset.glyphs.transform_values do |glyph|
            glyph.convert_to_true_type(tolerance)
          end
        rescue TypeError, ArgumentError => error
          raise TTFunk::Error, error.message
        end
    end
  end
end
