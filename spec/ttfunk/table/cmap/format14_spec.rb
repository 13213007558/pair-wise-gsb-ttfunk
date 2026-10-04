# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::Table::Cmap::Format14 do
  let(:font) { TTFunk::File.new(UVSFontBuilder.build) }
  let(:uvs) { font.cmap.uvs.first }

  it 'is a supported subtable' do
    expect(uvs.supported?).to eq(true)
  end

  it 'is not used as the Unicode charmap' do
    expect(uvs.unicode?).to eq(false)
    expect(font.cmap.unicode.first.format).to eq(4)
  end

  it 'lists variation selectors' do
    expect(uvs.variation_selectors).to eq(
      [UVSFontBuilder::SELECTOR, UVSFontBuilder::OTHER_SELECTOR],
    )
  end

  it 'exposes default UVS ranges' do
    expect(uvs.default_uvs_ranges(UVSFontBuilder::SELECTOR)).to eq(
      [[UVSFontBuilder::DEFAULT_BASE_CODE, 0]],
    )
    expect(uvs.default_uvs_ranges(UVSFontBuilder::OTHER_SELECTOR)).to eq([])
  end

  it 'exposes non-default UVS mappings' do
    expect(uvs.non_default_uvs_mappings(UVSFontBuilder::SELECTOR)).to eq(
      UVSFontBuilder::DEDICATED_BASE_CODE => UVSFontBuilder::DEDICATED_GLYPH_ID,
    )
  end

  describe '#[]' do
    it 'returns the mapped glyph for non-default UVS' do
      expect(uvs[UVSFontBuilder::DEDICATED_BASE_CODE, UVSFontBuilder::SELECTOR])
        .to eq(UVSFontBuilder::DEDICATED_GLYPH_ID)
    end

    it 'returns the glyph from the Unicode cmap for default UVS' do
      expect(uvs[UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::SELECTOR])
        .to eq(font.cmap.unicode.first[UVSFontBuilder::DEFAULT_BASE_CODE])
    end

    it 'returns nil for unsupported sequences' do
      expect(uvs[UVSFontBuilder::DEFAULT_BASE_CODE, 0xE0102]).to be_nil
      expect(uvs[0x43, UVSFontBuilder::SELECTOR]).to be_nil
    end
  end

  describe 'sequence predicates' do
    let(:default_code) { UVSFontBuilder::DEFAULT_BASE_CODE }
    let(:dedicated_code) { UVSFontBuilder::DEDICATED_BASE_CODE }
    let(:selector) { UVSFontBuilder::SELECTOR }
    let(:other_selector) { UVSFontBuilder::OTHER_SELECTOR }

    it 'recognizes default UVS sequences' do
      expect(uvs.default_uvs?(default_code, selector)).to eq(true)
      expect(uvs.default_uvs?(dedicated_code, selector)).to eq(false)
      expect(uvs.default_uvs?(default_code, other_selector)).to eq(false)
    end

    it 'recognizes non-default UVS sequences' do
      expect(uvs.non_default_uvs?(dedicated_code, selector)).to eq(true)
      expect(uvs.non_default_uvs?(default_code, selector)).to eq(false)
      expect(uvs.non_default_uvs?(default_code, other_selector)).to eq(true)
    end
  end

  describe 'malformed subtables' do
    it 'raises a locatable error for duplicate variation selectors' do
      font = TTFunk::File.new(
        UVSFontBuilder.build(
          uvs_records: [
            { selector: UVSFontBuilder::SELECTOR, default: [[0x41, 0]] },
            { selector: UVSFontBuilder::SELECTOR, default: [[0x42, 0]] },
          ],
        ),
      )

      expect { font.cmap.tables }.to raise_error(
        TTFunk::Error,
        /duplicate variation selector 0x0E0100/,
      )
    end

    it 'raises a locatable error for out of bounds default UVS offset' do
      font = TTFunk::File.new(
        UVSFontBuilder.build(
          uvs_records: [
            { selector: UVSFontBuilder::SELECTOR, default_offset: 0xFFFF },
          ],
        ),
      )

      expect { font.cmap.tables }.to raise_error(
        TTFunk::Error,
        /default UVS offset 65535 out of bounds for variation selector 0x0E0100/,
      )
    end

    it 'raises a locatable error for out of bounds non-default UVS offset' do
      font = TTFunk::File.new(
        UVSFontBuilder.build(
          uvs_records: [
            { selector: UVSFontBuilder::SELECTOR, non_default_offset: 0 },
            { selector: UVSFontBuilder::OTHER_SELECTOR, non_default_offset: 0xFFFF },
          ],
        ),
      )

      expect { font.cmap.tables }.to raise_error(
        TTFunk::Error,
        /non-default UVS offset 65535 out of bounds for variation selector 0x0E0101/,
      )
    end

    it 'raises a locatable error for tables exceeding the subtable length' do
      font = TTFunk::File.new(
        UVSFontBuilder.build(
          uvs_records: [
            { selector: UVSFontBuilder::SELECTOR, default: [[0x41, 0]] },
            { selector: UVSFontBuilder::OTHER_SELECTOR, default_offset: 36 },
          ],
        ),
      )

      expect { font.cmap.tables }.to raise_error(
        TTFunk::Error,
        /default UVS table at offset 36 exceeds subtable length 40 for variation selector 0x0E0101/,
      )
    end
  end
end
