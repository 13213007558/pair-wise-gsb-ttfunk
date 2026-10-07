# TTFunk

![Maintained: yes](https://img.shields.io/badge/maintained-yes-brightgreen.svg)
![CI status](https://github.com/prawnpdf/ttfunk/workflows/CI/badge.svg)

TTFunk is a TrueType and OpenType font library written in pure ruby. It supports
both parsing and encoding of fonts. Also provides limited font subsetting.

## Installation

The recommended installation method is via Rubygems.

```shell
gem install ttfunk
```

## Usage

Basic usage:

```ruby
require 'ttfunk'

file = TTFunk::File.open("some/path/myfont.ttf")
puts "name    : #{file.name.font_name.join(', ')}"
puts "ascent  : #{file.ascent}"
puts "descent : #{file.descent}"
```

For more detailed examples, explore the examples directory.

## Merging TrueType (`glyf`) fonts

Use {GlyfMerger} to add explicitly selected glyphs from fallback fonts. The
caller chooses the source font for every code point; conflicting selections are
not resolved automatically. All glyph IDs, composite component IDs, horizontal
metrics, and the Unicode `cmap` are reassigned in the output.

The primary font supplies the output `unitsPerEm`. Outlines and metrics from
other sources are scaled to that em square. Line metrics use the union of the
source typographic ascent/descent/line-gap boxes; Windows ascent/descent values
use the maximum source values.

```ruby
primary = TTFunk::File.open('primary.ttf')
fallback = TTFunk::File.open('fallback.ttf')

result = TTFunk::GlyfMerger.merge(primary, 0x100 => fallback)

if result.success?
  File.binwrite('merged.ttf', result.font)
else
  warn result.restrictions.map(&:message)
end
```

Only TrueType `glyf` fonts are accepted. A result with restrictions has `font`
set to `nil`; this prevents emitting a font with unresolved layout, variation,
CFF, vertical, color-bitmap, or composite-glyph references. Use `merge!` to
raise {GlyfMergeError} instead of returning the restriction list.

## Licensing

Matz's terms for Ruby, GPLv2, or GPLv3. See LICENSE for details.

##  Authorship

This project is maintained by the same folks who run the Prawn PDF project.

Here's the [full list](https://github.com/prawnpdf/ttfunk/contributors) of
Github users who have at least one patch accepted to TTFunk.

## Community support

TTFunk is maintained as a dependency of Prawn, the ruby PDF generation library.

Any questions or feedback should be sent to the [Prawn
Discussions](https://github.com/orgs/prawnpdf/discussions) group.
