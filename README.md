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

## Merging fonts

A primary font missing a few characters can be supplemented with glyphs from
fallback fonts, producing a single TrueType font suitable for embedding:

```ruby
require 'ttfunk'

merger = TTFunk::Merger.new(TTFunk::File.open('primary.ttf'))

# The caller explicitly chooses the source font for each character.
# Conflicts (a character already covered by the primary font, or assigned
# twice) raise an error instead of being resolved by guessing.
merger.add(0x4E2D, TTFunk::File.open('fallback.ttf')) # 中

result = merger.merge
result.font        # => binary TrueType font, ready for embedding
result.charmap     # => { 0x4E2D => glyph_id, ... }
result.limitations # => unmigratable tables (layout, variations, ...)
```

The merged font uses the primary font's units-per-em (fallback outlines and
metrics are scaled to it), re-assigns all glyph IDs and character mappings,
and migrates composite glyph components along with the glyphs that reference
them. Global vertical metrics (ascent/descent/line gap) from all contributing
fonts are combined as an enclosing envelope: the highest ascent, the lowest
descent, and the largest line gap.

Only glyf-based TrueType fonts are supported. Tables that can't be migrated
(layout tables such as GSUB/GPOS/kern, variation tables such as fvar/gvar)
are dropped and reported in the limitation list rather than producing a font
with broken internal references.

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
