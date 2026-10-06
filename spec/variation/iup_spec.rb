# frozen_string_literal: true

require 'ttfunk'
require 'ttfunk/variation/iup'

RSpec.describe TTFunk::Variation::Iup do
  # Triangle contour with points A, B, C. B is omitted; phantoms carry no
  # deltas and must stay at zero.
  let(:coordinates) do
    [
      [0, 0], [10, 0], [10, 10],   # contour
      [0, 0], [20, 0], [0, 0], [0, 0] # four phantom points
    ]
  end

  let(:contour_ends) { [2] }

  it 'linearly interpolates an omitted point on the contour' do
    deltas = [
      [0, 10], nil, [20, 10],
      nil, nil, nil, nil
    ]

    result = described_class.expand(deltas, coordinates, contour_ends)
    expect(result[1]).to eq([20.0, 10.0])
  end

  it 'wraps interpolation around the ends of a closed contour' do
    # Only the middle point is explicit; first point wraps from the last.
    deltas = [
      nil, [4, 4], nil,
      nil, nil, nil, nil
    ]
    result = described_class.expand(deltas, coordinates, contour_ends)
    expect(result[0]).to eq([4.0, 4.0])
    expect(result[2]).to eq([4.0, 4.0])
  end

  it 'defaults omitted phantom points to zero' do
    deltas = [
      [0, 0], [0, 0], [0, 0],
      nil, nil, nil, nil
    ]
    result = described_class.expand(deltas, coordinates, contour_ends)
    expect(result[3..6]).to all(eq([0.0, 0.0]))
  end

  it 'returns the deltas untouched when nothing is omitted' do
    deltas = [[1, 1]] * 7
    expect(described_class.expand(deltas, coordinates, contour_ends)).to eq(
      deltas
    )
  end
end
