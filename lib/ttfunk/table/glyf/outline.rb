# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # A single point of a glyph outline.
      #
      # @!attribute [rw] x
      #   @return [Integer, Float] x-coordinate.
      # @!attribute [rw] y
      #   @return [Integer, Float] y-coordinate.
      # @!attribute [rw] on_curve
      #   @return [Boolean] whether this is an on-curve point.
      OutlinePoint = Struct.new(:x, :y, :on_curve)

      # Fully expanded glyph outline. Compound glyphs are decomposed into
      # their component points, so points of nested components appear in
      # component expansion order.
      #
      # @!attribute [rw] points
      #   @return [Array<OutlinePoint>] outline points.
      # @!attribute [rw] end_points_of_contours
      #   @return [Array<Integer>] point indices of the last point of each
      #     contour.
      # @!attribute [rw] horizontal_metrics
      #   @return [TTFunk::Table::Hmtx::HorizontalMetric] effective horizontal
      #     metrics of the glyph (accounts for USE_MY_METRICS in compound
      #     glyphs).
      Outline =
        Struct.new(:points, :end_points_of_contours, :horizontal_metrics)
    end
  end
end
