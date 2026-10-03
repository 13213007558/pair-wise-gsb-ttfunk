# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Horizontal Metrics (`hmtx`) table.
    class Hmtx < Table
      # Glyph horizontal metrics.
      # @return [Array<HorizontalMetric>]
      attr_reader :metrics

      # Left side bearings.
      # @return [Array<Ingteger>]
      attr_reader :left_side_bearings

      # Glyph widths.
      # @return [Array<Integer>]
      attr_reader :widths

      # Encode table.
      #
      # @param hmtx [TTFunk::Table::Hmtx]
      # @param mapping [Hash{Integer => Integer}] keys are new glyph IDs, values
      #   are old glyph IDs
      # @return [Hash{:number_of_metrics => Integer, :table => String}]
      #   * `:number_of_metrics` - number of mertrics is the table.
      #   * `:table` - encoded table.
      def self.encode(hmtx, mapping, glyphs = nil)
        metrics =
          mapping.keys.sort.map { |new_id|
            old_id = mapping[new_id]
            converted_glyph = glyphs&.[](old_id)
            metric =
              if converted_glyph.respond_to?(:horizontal_metrics)
                converted_glyph.horizontal_metrics
              else
                hmtx.for(old_id)
              end
            [metric.advance_width, metric.left_side_bearing]
          }

        {
          number_of_metrics: metrics.length,
          table: metrics.flatten.pack('n*'),
        }
      end

      # Horyzontal glyph metric.
      #
      # @!attribute [rw] advance_width
      #   @return [Integer] Advance width.
      # @!attribute [rw] left_side_bearing
      #   @return [Integer] Left side bearing.
      HorizontalMetric = Struct.new(:advance_width, :left_side_bearing)

      # Get horizontal metric for glyph.
      #
      # @param glyph_id [Integer]
      # @return [HorizontalMetric]
      def for(glyph_id)
        @metrics[glyph_id] ||
          metrics_cache[glyph_id] ||=
            HorizontalMetric.new(
              @metrics.last.advance_width,
              @left_side_bearings[glyph_id - @metrics.length],
            )
      end

      private

      def metrics_cache
        @metrics_cache ||= {}
      end

      def parse!
        @metrics = []

        file.horizontal_header.number_of_metrics.times do
          advance = read(2, 'n').first
          lsb = read_signed(1).first
          @metrics.push(HorizontalMetric.new(advance, lsb))
        end

        lsb_count = file.maximum_profile.num_glyphs -
          file.horizontal_header.number_of_metrics
        @left_side_bearings = read_signed(lsb_count)

        @widths = @metrics.map(&:advance_width)
        @widths += [@widths.last] * @left_side_bearings.length
      end
    end
  end
end
