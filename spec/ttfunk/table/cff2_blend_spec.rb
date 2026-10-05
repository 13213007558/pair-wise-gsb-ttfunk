# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk'

RSpec.describe TTFunk::Table::Cff2::Charstring do
  let(:coordinates) { { wght: 0.4 } }
  let(:scalars) { [0.4, 0.6] }
  let(:store) do
    values = scalars
    object = Object.new
    object.define_singleton_method(:deltas) { |*_args| values }
    object
  end
  let(:charstring) do
    described_class.allocate.tap do |cs|
      cs.instance_variable_set(:@coordinates, coordinates)
      cs.instance_variable_set(:@stack, [])
      cs.instance_variable_set(:@data, [])
      cs.instance_variable_set(:@index, 0)
      cs.instance_variable_set(:@path, TTFunk::Table::Cff::Path.new)
      cs.instance_variable_set(:@x, 0)
      cs.instance_variable_set(:@y, 0)
      cs.instance_variable_set(:@open, false)
      cs.instance_variable_set(:@vsindex, 0)
      cs.instance_variable_set(:@variation_store, store)
    end
  end

  it 'combines multiple active region deltas as one blend expression' do
    charstring.instance_variable_set(:@stack, [100, 10, 50, 1])
    charstring.__send__(:blend)
    expect(charstring.instance_variable_get(:@stack)).to eq([134.0])
  end

  it 'preserves the selected variation index across a subroutine' do
    charstring.instance_variable_set(:@vsindex, 0)
    charstring.instance_variable_set(:@stack, [3])
    charstring.__send__(:vsindex)
    expect(charstring.instance_variable_get(:@vsindex)).to eq(3)
    expect(charstring.instance_variable_get(:@stack)).to eq([])
  end

  it 'continues the same operand stack after a subroutine changes the selected index' do
    subroutines = Object.new
    subroutines.define_singleton_method(:[]) { |_index| [140, 15, 11].pack('C*') }

    integration_store = Object.new
    integration_store.define_singleton_method(:deltas) { |index, *_args|
      raise unless [0, 1].include?(index)
      if index == 1
        [0.5, 0.5]
      else
        [0.4, 0.6]
      end
    }
    charstring.instance_variable_set(:@variation_store, integration_store)
    charstring.instance_variable_set(:@subrs, subroutines)
    charstring.instance_variable_set(:@subrs_bias, 0)
    charstring.instance_variable_set(:@call_frames, [])
    charstring.instance_variable_set(:@stack, [0])
    charstring.__send__(:callsubr)
    charstring.instance_variable_set(:@stack, [1])
    charstring.__send__(:vsindex)
    expect(charstring.instance_variable_get(:@vsindex)).to eq(1)
    expect(charstring.instance_variable_get(:@stack)).to eq([])

    charstring.instance_variable_set(:@stack, [105, 10, 1])
    charstring.__send__(:blend)

    expect(charstring.instance_variable_get(:@stack)).to eq([110.0])
  end

  it 'raises before mutating the operand stack when blend is underflowed' do
    charstring.instance_variable_set(:@stack, [100, 1])
    expect { charstring.__send__(:blend) }.to raise_error(
      described_class::InsufficientOperandsError,
      'blend requires 3 operands but 2 are available'
    )
    expect(charstring.instance_variable_get(:@stack)).to eq([100, 1])
  end
end
