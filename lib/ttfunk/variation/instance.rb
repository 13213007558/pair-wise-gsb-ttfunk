# frozen_string_literal: true

require_relative 'glyph_outline'
require_relative 'iup'
require_relative '../table/simple'

module TTFunk
  module Variation
    # Freezes a variable TrueType font at one location of its variation
    # axis space, producing a static (non-variable) font.
    #
    # The instance is computed by:
    # 1. normalizing (and clamping) the requested coordinates with `fvar`,
    # 2. applying the optional `avar` piecewise linear segment map,
    # 3. evaluating every applicable `gvar` tuple's tent scalar,
    # 4. summing the tuples' deltas (with IUP interpolation for the omitted
    #    outline points) onto the default outlines and phantom points,
    # 5. rebuilding `glyf`, `loca`, `hmtx`, `hhea`, `head`, `maxp` and the
    #    `cvt ` table (when `cvar` is present).
    #
    # The output no longer contains any variation tables.
    class Instance
      # Variation tables that influence shaping, metrics or outlines but
      # are not understood by this implementation. Their presence makes a
      # complete instance impossible, so an error is raised instead of
      # silently dropping them.
      #
      # `STAT` is intentionally excluded: it only describes the axes and
      # named values and remains valid, if redundant, in a static font.
      UNSUPPORTED_VARIATION_TABLES = %w[MVAR HVAR VVAR].freeze

      # Variation tables removed from every instance.
      REMOVED_VARIATION_TABLES = %w[fvar avar gvar cvar].freeze

      class << self
        # Convenience wrapper around {#initialize} and {#generate}.
        #
        # @param file [TTFunk::File]
        # @param coordinates [Hash{String, Symbol => Numeric}]
        # @return [Hash] see {#generate}
        def generate(file, coordinates)
          new(file, coordinates).generate
        end
      end

      # @param file [TTFunk::File] the variable source font.
      # @param coordinates [Hash{String, Symbol => Numeric}] desired location
      #   in design units, e.g. <tt>{ 'wght' => 700 }</tt>. Coordinates
      #   outside an axis' range are clamped; omitted axes use the default.
      def initialize(file, coordinates)
        @file = file
        @requested = coordinates.each_with_object({}) do |(tag, value), memo|
          memo[tag.to_s] = value.to_f
        end
      end

      # Build the static font.
      #
      # @return [Hash]
      #   * `:font` (<tt>String</tt>) - static font binary data.
      #   * `:location` (<tt>Hash{String => Float}</tt>) - normalized and
      #     avar-mapped coordinates that were actually used (post-clamp).
      #   * `:removed_tables` (<tt>Array<String></tt>) - dropped tables.
      #   * `:rewritten_tables` (<tt>Array<String></tt>) - rebuilt tables.
      #   * `:copied_tables` (<tt>Array<String></tt>) - tables copied through
      #     verbatim.
      def generate
        ensure_variable_font!
        ensure_supported!

        location = normalized_location
        glyphs = instantiate_glyphs(location)
        cvt = instantiate_cvt(location)

        encoder = StaticEncoder.new(
          @file, glyphs, removed_tables, cvt
        )
        result = encoder.encode

        {
          font: result[:font],
          location: location,
          removed_tables: removed_tables,
          rewritten_tables: result[:rewritten_tables],
          copied_tables: result[:copied_tables],
        }
      end

      # Tables removed from the source font.
      #
      # @return [Array<String>]
      def removed_tables
        @removed_tables ||=
          (REMOVED_VARIATION_TABLES + ['DSIG']).select do |tag|
            @file.directory_info(tag)
          end
      end

      private

      def ensure_variable_font!
        return if @file.fvar.exists?

        raise Error,
          'cannot instantiate: font has no fvar table'
      end

      def ensure_supported!
        unsupported = UNSUPPORTED_VARIATION_TABLES.select do |tag|
          @file.directory_info(tag)
        end
        return if unsupported.empty?

        message = +'cannot produce a complete static instance: the font '
        message << 'contains unsupported variation tables: '
        message << unsupported.join(', ')
        raise Error, message
      end

      # Normalize (with clamping to the valid axis range) and apply avar.
      def normalized_location
        normalized = @file.fvar.axes.to_h do |axis|
          value = @requested.fetch(axis.tag, axis.default_value)
          [axis.tag, axis.normalize(value)]
        end

        normalized = @file.avar.apply(normalized) if @file.avar.exists?
        normalized = normalized.transform_values do |value|
          Table::Fvar::F2DOT14.round(value)
        end
        normalized
      end

      # Build glyphs in two passes: every glyph's outlines and metrics are
      # interpolated first, then composite bounding boxes are resolved once
      # the glyphs they reference are available.
      #
      # @return [Hash{Integer => InstantiatedGlyph}]
      def instantiate_glyphs(location)
        count = @file.maximum_profile.num_glyphs
        glyphs = {}

        count.times do |glyph_id|
          glyphs[glyph_id] = build_glyph(glyph_id, location, glyphs)
        end

        resolve_composite_bounds(glyphs)
        glyphs
      end

      def build_glyph(glyph_id, location, glyphs)
        raw_glyph = @file.glyph_outlines.for(glyph_id)
        metric = @file.horizontal_metrics.for(glyph_id)
        variations =
          if @file.gvar.exists?
            point_count =
              if raw_glyph&.compound?
                raw_glyph.glyph_ids.length + 4
              elsif raw_glyph
                raw_glyph.end_point_of_last_contour + 4
              else
                4
              end
            @file.gvar.for(glyph_id, point_count)
          else
            []
          end

        resolver = ->(component_id) { glyphs[component_id] }
        InstantiatedGlyph.new(
          glyph_id, raw_glyph, metric, variations, location, resolver
        )
      end

      def resolve_composite_bounds(glyphs)
        glyphs.each_value do |glyph|
          glyph.resolve_composite if glyph.compound?
        end
      end

      def instantiate_cvt(location)
        return nil unless @file.directory_info('cvar')

        raw_cvt = Table::Simple.new(@file, 'cvt ').raw
        values = raw_cvt.unpack('s>*')
        deltas = Array.new(values.length, 0.0)
        applied = false
        @file.cvar.variations(values.length).each do |variation|
          scalar = Scalar.for_region(variation.axes, location)
          next if scalar.zero?
          applied = true

          variation.deltas.each_with_index do |delta, index|
            deltas[index] += (delta || 0) * scalar
          end
        end

        return raw_cvt unless applied

        values.each_with_index.map do |value, index|
          clamp_int16(ot_round(value + deltas[index]))
        end.pack('s>*')
      end

      def ot_round(value)
        (value + 0.5).floor
      end

      def clamp_int16(value)
        [[value, 32_767].min, -32_768].max.to_i
      end
    end
  end
end

require_relative 'instance/instantiated_glyph'
require_relative 'static_encoder'
