# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cff2'

RSpec.describe TTFunk::Table::Cff2::Charstring do
  let(:axis) do
    TTFunk::Table::Fvar::Axis.new(
      tag: :wght,
      min_value: 0,
      default_value: 400,
      max_value: 800,
    )
  end

  let(:store) do
    double(
      region_0: [
        [0.0, 0.5, 1.0],
      ],
      region_1: [
        [0.5, 1.0, 1.0],
      ],
    )
  end

  let(:top_dict) { Struct.new(:variation_store).new(store) }
  let(:coordinates) { { wght: 0.75 } }

  before do
    allow(store).to receive(:region_count) { |vsindex| vsindex.zero? ? 2 : 1 }
    allow(store).to receive(:delta) do |vsindex, deltas, values|
      scalar = axis.normalized(values[:wght])

      scalars = vsindex.zero? ? [0.4, 0.6] : [scalar]
      deltas.each_with_index.sum { |delta, index| delta * scalars[index] }
    end
  end

  it 'combines multiple region deltas in one blend operator' do
    # 10 0 2 4 0 4 0 0 blend 2; 21 = rmoveto; 6 0 rlineto; 14 = endchar
    charstring = described_class.new(
      0,
      top_dict,
      nil,
      [149, 139, 141, 143, 139, 143, 16, 141, 21, 145, 139, 5, 14],
      coordinates,
    )

    expect(charstring.path.commands).to eq(
      [
        [:move, 10.8, 4.0],
        [:line, 16.8, 4.0],
        [:close],
      ],
    )
  end

  it 'preserves the operand stack and vsindex across a subroutine call' do
    subrs = double(bias: 107)
    allow(subrs).to receive(:[]).with(0).and_return(
      [
        15, 140, # vsindex 1
        11,    # return without consuming the caller operand stack
      ],
    )

    private_dict = Struct.new(:subr_index, :vsindex).new(subrs, 0)
    font_dict = Struct.new(:private_dict).new(private_dict)
    # 20 0 -107 callsubr; 21 rmoveto; 10 0 blend 1; 6 hlineto; 14 endchar
    raw = [159, 139, 32, 10, 21, 149, 139, 16, 140, 6, 14]
    charstring = described_class.new(0, top_dict, font_dict, raw, coordinates)

    expect(charstring.path.commands).to eq(
      [
        [:move, 20, 0],
        [:line, 30, 0],
        [:close],
      ],
    )
  end

  it 'does not consume operands when blend operands are insufficient' do
    charstring = described_class.new(
      0,
      top_dict,
      nil,
      [149, 16, 141], # 10 blend 2, with only one default and no deltas
      coordinates,
    )

    expect { charstring.path }.to raise_error(
      described_class::InsufficientOperandsError,
      /blend requires 6 operands.*1 values were available/,
    )
  end
end
