# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset'

describe 'UVS subsetting' do # rubocop: disable RSpec/DescribeClass
  let(:font) { TTFunk::File.new(UVSFontBuilder.build) }
  let(:subset) { TTFunk::Subset.for(font, :unicode) }
  let(:new_font) { TTFunk::File.new(subset.encode) }
  let(:new_uvs) { new_font.cmap.uvs.first }

  it 'exports requested variation sequences' do
    subset.use(UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::SELECTOR)
    subset.use(UVSFontBuilder::DEDICATED_BASE_CODE, UVSFontBuilder::SELECTOR)

    # the default variant query resolves to the base glyph from the Unicode
    # cmap of the subset font
    expect(new_uvs[UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::SELECTOR])
      .to eq(new_font.cmap.unicode.first[UVSFontBuilder::DEFAULT_BASE_CODE])
    expect(new_uvs[UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::SELECTOR])
      .to eq(2)

    # the dedicated variant query returns the renumbered variant glyph
    expect(new_uvs[UVSFontBuilder::DEDICATED_BASE_CODE, UVSFontBuilder::SELECTOR])
      .to eq(4)
  end

  it 'renumbers variant glyphs and their compound dependencies consistently' do
    subset.use(UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::SELECTOR)
    subset.use(UVSFontBuilder::DEDICATED_BASE_CODE, UVSFontBuilder::SELECTOR)

    # glyph 4 in the original font is a compound glyph referencing glyph 6;
    # in the subset the component is renumbered to 5
    variant = new_font.glyph_outlines.for(4)
    expect(variant).to be_compound
    expect(variant.glyph_ids).to eq([5])
    expect(new_font.glyph_outlines.for(5)).to_not be_nil
    expect(new_font.maximum_profile.num_glyphs).to eq(6)
  end

  it 'does not retain unrequested selector records' do
    subset.use(UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::SELECTOR)
    subset.use(UVSFontBuilder::DEDICATED_BASE_CODE, UVSFontBuilder::SELECTOR)

    expect(new_uvs.variation_selectors).to eq([UVSFontBuilder::SELECTOR])
    expect(
      new_uvs[UVSFontBuilder::DEFAULT_BASE_CODE, UVSFontBuilder::OTHER_SELECTOR],
    ).to be_nil
  end

  it 'includes the base character of requested sequences' do
    subset.use(UVSFontBuilder::DEDICATED_BASE_CODE, UVSFontBuilder::SELECTOR)

    expect(new_font.cmap.unicode.first[UVSFontBuilder::DEDICATED_BASE_CODE])
      .to be_positive
  end

  it 'omits the format 14 subtable when no sequences are requested' do
    subset.use(UVSFontBuilder::DEFAULT_BASE_CODE)

    expect(new_font.cmap.uvs).to be_empty
    expect(new_font.cmap.unicode.first[UVSFontBuilder::DEFAULT_BASE_CODE])
      .to be_positive
  end

  it 'raises a locatable error for unsupported sequences' do
    subset.use(0x41, 0xE0000)

    expect { subset.encode }.to raise_error(
      TTFunk::Error,
      /variation sequence U\+0041 U\+0E0000 is not supported/,
    )
  end

  it 'raises a locatable error when the font has no UVS subtable' do
    font = TTFunk::File.open(test_font('DejaVuSans'))
    subset = TTFunk::Subset.for(font, :unicode)
    subset.use(0x41, 0xE0100)

    expect { subset.encode }.to raise_error(
      TTFunk::Error,
      /variation sequence U\+0041 U\+0E0100 is not supported/,
    )
  end

  it 'knows which sequences it includes' do
    expect(subset.includes?(0x41, UVSFontBuilder::SELECTOR)).to eq(false)
    expect(subset.includes?(0x41)).to eq(false)

    subset.use(0x41, UVSFontBuilder::SELECTOR)

    expect(subset.includes?(0x41, UVSFontBuilder::SELECTOR)).to eq(true)
    expect(subset.includes?(0x41)).to eq(true)
    expect(subset.includes?(0x41, UVSFontBuilder::OTHER_SELECTOR)).to eq(false)
  end
end
