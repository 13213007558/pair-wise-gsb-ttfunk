# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/fvar'

RSpec.describe TTFunk::Table::Fvar do
  let(:axis) do
    described_class::Axis.new(
      tag: :wght,
      min_value: 100,
      default_value: 400,
      max_value: 1000,
    )
  end

  it 'normalizes user-space coordinates below and above the default' do
    expect(axis.normalized(250)).to eq(-0.5)
    expect(axis.normalized(700)).to eq(0.5)
  end

  it 'applies avar segment mappings' do
    fvar = described_class.allocate
    fvar.instance_variable_set(:@axes, [axis])
    mappings = { 0 => { -1.0 => -1.0, -0.5 => -0.25, 0.0 => 0.0, 0.5 => 0.25, 1.0 => 1.0 } }

    expect(fvar.normalize({ wght: 250 }, mappings)).to eq(wght: -0.25)
    expect(fvar.normalize({ wght: 700 }, mappings)).to eq(wght: 0.25)
  end
end
