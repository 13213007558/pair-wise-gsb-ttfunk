# frozen_string_literal: true

module TTFunk
  module CffToTtf
    # Encodes quadratic contours as a simple +glyf+ table glyph.
    #
    # The glyph carries no instructions: CFF hints are not translated to
    # TrueType instructions, so the instruction stream is empty.
    module GlyphEncoder
      # Flag: point is on the curve.
      ON_CURVE = 0x01
      # Flag: x coordinate is stored in one byte.
      X_SHORT = 0x02
      # Flag: y coordinate is stored in one byte.
      Y_SHORT = 0x04
      # Flag: x coordinate is the same as the previous one (or, combined
      # with X_SHORT, the stored byte is positive).
      X_SAME_OR_POSITIVE = 0x10
      # Flag: y coordinate is the same as the previous one (or, combined
      # with Y_SHORT, the stored byte is positive).
      Y_SAME_OR_POSITIVE = 0x20

      # Encoded glyph along with its derived metrics.
      EncodedGlyph = Struct.new(
        :raw,
        :number_of_contours,
        :number_of_points,
        :x_min,
        :y_min,
        :x_max,
        :y_max,
        keyword_init: true
      ) do
        # Empty glyphs have no bounding box.
        # @return [Boolean]
        def empty?
          number_of_contours.zero?
        end
      end

      module_function

      # Encode contours into a simple glyph.
      #
      # @param contours [Array<Array<Array(Integer, Integer, Boolean)>>]
      #   contours as produced by {PathConverter}.
      # @return [EncodedGlyph]
      def encode(contours)
        if contours.empty?
          return EncodedGlyph.new(
            raw: +''.b,
            number_of_contours: 0,
            number_of_points: 0,
            x_min: 0,
            y_min: 0,
            x_max: 0,
            y_max: 0,
          )
        end

        end_points = []
        points_count = 0
        contours.each do |contour|
          points_count += contour.length
          end_points << points_count - 1
        end

        xs = []
        ys = []
        flags = +''.b
        x_coordinates = +''.b
        y_coordinates = +''.b
        previous_x = 0
        previous_y = 0

        contours.each do |contour|
          contour.each do |x, y, on_curve|
            xs << x
            ys << y

            flag = on_curve ? ON_CURVE : 0
            delta_x = x - previous_x
            delta_y = y - previous_y
            previous_x = x
            previous_y = y

            if delta_x.zero?
              flag |= X_SAME_OR_POSITIVE
            elsif delta_x.between?(1, 255)
              flag |= X_SHORT | X_SAME_OR_POSITIVE
              x_coordinates << delta_x.chr
            elsif delta_x.between?(-255, -1)
              flag |= X_SHORT
              x_coordinates << (-delta_x).chr
            else
              x_coordinates << [delta_x].pack('s>')
            end

            if delta_y.zero?
              flag |= Y_SAME_OR_POSITIVE
            elsif delta_y.between?(1, 255)
              flag |= Y_SHORT | Y_SAME_OR_POSITIVE
              y_coordinates << delta_y.chr
            elsif delta_y.between?(-255, -1)
              flag |= Y_SHORT
              y_coordinates << (-delta_y).chr
            else
              y_coordinates << [delta_y].pack('s>')
            end

            flags << flag.chr
          end
        end

        x_min = xs.min
        y_min = ys.min
        x_max = xs.max
        y_max = ys.max

        raw = +''.b
        raw << [contours.length, x_min, y_min, x_max, y_max].pack('s>5')
        raw << end_points.pack('n*')
        raw << [0].pack('n') # instruction length: no instructions
        raw << flags
        raw << x_coordinates
        raw << y_coordinates

        EncodedGlyph.new(
          raw: raw,
          number_of_contours: contours.length,
          number_of_points: points_count,
          x_min: x_min,
          y_min: y_min,
          x_max: x_max,
          y_max: y_max,
        )
      end
    end
  end
end
