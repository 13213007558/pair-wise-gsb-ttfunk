# frozen_string_literal: true

require 'stringio'

require 'spec_helper'
require 'ttfunk/table/cff2'

RSpec.describe TTFunk::Table::Cff2::VariationStore do
  let(:axis) do
    TTFunk::Table::Fvar::Axis.new(
      tag: :wght,
      min_value: 0,
      default_value: 400,
      max_value: 800,
    )
  end

  let(:data) do
    region_axis = [0.0, 0.5, 1.0].map do |value|
      [(value * 16_384).round].pack('s>')
    end.join
    region_list = [1, 1].pack('nn') + region_axis
    var_data = [0, 0, 1, 0].pack('nnnn')

    item_store = [
      [1].pack('n') + [12].pack('N') + [1].pack('n'),
      [22].pack('N'),
      region_list,
      var_data,
    ].join

    [[item_store.length].pack('n'), item_store, '\x00\x00'].join
  end

  let(:file) { double(contents: StringIO.new(data)) }

  it 'interpolates deltas using the selected vsindex and region scalars' do
    store = described_class.new(file, 2, [axis], data.bytesize - 2)

    expect(store.region_count(0)).to eq(1)
    expect(store.delta(0, [4], { wght: 0.25 })).to eq(2.0)
  end
end
