# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::Table::Gsub do
  let(:font) { TTFunk::File.open(test_font('DejaVuSans')) }
  let(:gsub) { font.gsub }

  it 'exists in DejaVuSans' do
    expect(gsub.exists?).to be(true)
  end

  it 'parses the header' do
    expect(gsub.version).to eq(0x00010000)
  end

  it 'parses the script list' do
    expect(gsub.scripts.keys).to include('DFLT', 'latn', 'arab')
    expect(gsub.scripts['latn'][:default]).to be_a(Hash)
  end

  it 'parses the feature list' do
    tags = gsub.features.map { |feature| feature[:tag] }
    expect(tags).to include('liga', 'ccmp')
    expect(gsub.features).to all(include(:tag, :lookup_indices))
  end

  it 'parses the lookup list' do
    expect(gsub.lookups.length).to eq(39)
    expect(gsub.lookups.map(&:type).tally).to eq(1 => 22, 3 => 1, 4 => 12, 6 => 4)
  end

  it 'parses lookup subtables lazily' do
    lookup = gsub.lookups.find { |l| l.type == 4 }
    subtable = lookup.subtables.first
    expect(subtable[:type]).to eq(4)
    expect(subtable[:coverage]).to be_a(TTFunk::Table::Gsub::Coverage)
    expect(subtable[:ligature_sets].first.first).to include(:ligature, :components)
  end

  describe '#langsys_for' do
    it 'finds the requested script' do
      expect(gsub.langsys_for(script: 'latn')).to eq(gsub.scripts['latn'][:default])
    end

    it 'falls back to DFLT for unknown scripts' do
      expect(gsub.langsys_for(script: 'zzzz')).to eq(gsub.scripts['DFLT'][:default])
    end
  end

  describe '#feature_indices_for' do
    it 'selects features by tag' do
      indices = gsub.feature_indices_for(script: 'latn', feature_tags: ['liga'])
      expect(indices).to_not be_empty
      expect(indices.map { |i| gsub.features[i][:tag] }.uniq).to eq(['liga'])
    end

    it 'returns all features when no tags are given' do
      all = gsub.feature_indices_for(script: 'latn')
      some = gsub.feature_indices_for(script: 'latn', feature_tags: ['liga'])
      expect(all.length).to be > some.length
    end
  end

  describe '#lookups_for' do
    it 'returns lookups of enabled features in lookup list order' do
      lookups = gsub.lookups_for(script: 'latn', features: ['liga'])
      expect(lookups).to_not be_empty
      expect(lookups.map(&:type)).to eq([4])
    end
  end
end

RSpec.describe TTFunk::Table::Gsub::Coverage do
  it 'round-trips format 1' do
    coverage = described_class.new([3, 1, 7])
    parsed = described_class.parse(coverage.encode, 0)
    expect(parsed.glyphs).to eq([1, 3, 7])
  end

  it 'parses format 2' do
    data = [2, 2, 1, 3, 0, 10, 12, 5].pack('nnnnnnnn')
    parsed = described_class.parse(data, 0)
    expect(parsed.glyphs).to eq([1, 2, 3, 10, 11, 12])
  end

  it 'remaps glyphs dropping the missing ones' do
    coverage = described_class.new([1, 2, 3])
    remapped = coverage.remap(1 => 10, 3 => 30)
    expect(remapped.glyphs).to eq([10, 30])
    expect(coverage.remap(5 => 50)).to be_nil
  end
end

RSpec.describe TTFunk::Table::Gsub::ClassDef do
  it 'parses format 1' do
    data = [1, 5, 3, 7, 8, 9].pack('nnnnnn')
    parsed = described_class.parse(data, 0)
    expect(parsed.classes).to eq(5 => 7, 6 => 8, 7 => 9)
  end

  it 'round-trips format 2' do
    class_def = described_class.new(1 => 2, 2 => 2, 3 => 2, 9 => 1)
    parsed = described_class.parse(class_def.encode, 0)
    expect(parsed.classes).to eq(1 => 2, 2 => 2, 3 => 2, 9 => 1)
  end

  it 'defaults to class 0' do
    expect(described_class.new({}).class_of(42)).to eq(0)
  end

  it 'remaps glyphs dropping the missing ones' do
    class_def = described_class.new(1 => 2, 3 => 4)
    expect(class_def.remap(1 => 10).classes).to eq(10 => 2)
  end
end
