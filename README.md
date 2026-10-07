# text-hyphen

- home :: https://rubygems.org/gems/text-hyphen
- issues :: https://rubygems.org/gems/text-hyphen/issues

## Description

Text::Hyphen is a Ruby library to hyphenate words in various languages using
Ruby-fied versions of TeX hyphenation patterns. It will properly hyphenate
various words according to the rules of the language the word is written in. The
algorithm is based on that of the TeX typesetting system by Donald E. Knuth.

This is originally based on the Perl implementation of [TeX::Hyphen][] and the
[Ruby port][]. The language hyphenation pattern files are based on the sources
available from [CTAN][] as of 2004.12.19 and have been manually translated by
Austin Ziegler.

This is a small feature release adding Russian language support and fixing a bug
in the custom hyphen support introduced last version. This release provides both
Ruby 1.8.7 and Ruby 1.9.2 support (but please read below). In short, Ruby 1.8
support is deprecated and I will not be providing any bug fixes related to Ruby
1.8. New features will be developed and tested against Ruby 1.9 only.

## Synopsis

```ruby
require "text/hyphen"

hh = Text::Hyphen.new(language: 'en_us', left: 2, right: 2)
# which is the same as
hh = Text::Hyphen.new

word = "representation"
points = hh.hyphenate(word) #=> [3, 5, 8, 10]
puts hh.visualize(word) #=> rep-re-sen-ta-tion

# Phrases are also supported
phrase = "This useful library supports sentences."
points = hh.hyphenate(phrase)  #=> [8, 14, 23, 27, 34, 44]
puts hh.visualize(phrase)      #=> This use-ful li-brary sup-port-s phras-es and sen-tences.
```

Both visualize and hyphenate_to methods allow choosing a custom hyphen:

```ruby
puts hh.visualize(word, "&shy;") #=> rep&shy;re&shy;sen&shy;ta&shy;tion
```

Text::Hyphen is truly multilingual, with 29 languages or language variants
supported. As an example, consider the difference between the following:

```ruby
require 'text/hyphen'

# Using left and right minimum values of 0 ensures that you will see all
# possible hyphenation points, not just those that meet the minimum width
# requirements.
en = Text::Hyphen.new(left: 0, right: 0)
fr = Text::Hyphen.new(language: "fr", left: 0, right: 0)

puts en.visualise("organiser") #=> or-gan-iser
puts fr.visualise("organiser") #=> or-ga-ni-ser
```

As you can see, the hyphenation is distinct between the two hyphenators.
Improvements over TeX::Hyphen include thread safety (except for debug control)
and support for UTF-8 under Ruby 1.9.

## Training Custom Patterns

If you have a domain word list with the allowed break positions marked,
`Text::Hyphen::Trainer` can learn a compact set of TeX-style patterns that
loads directly into Text::Hyphen, instead of adding one exception per word.
Training is fully offline and never modifies the language data shipped with
the library.

```ruby
require "text/hyphen/trainer"

trainer = Text::Hyphen::Trainer.new(
  left: 1,              # minimum letters left of a break
  right: 1,             # minimum letters right of a break
  budget: 100,          # maximum number of patterns to learn
  false_break_cost: 1,  # cost of a break the annotation forbids
  missed_break_cost: 1, # cost of an allowed break not found
  validation_fraction: 0.25, # held-out words for validation
  seed: 42              # makes the validation split reproducible
)
result = trainer.train(%w[go-ing leav-ing play-ing re-play un-do through])

puts result.summary
puts result.pattern_text       # loadable with Text::Hyphen::Language#patterns
result.hyphenator              # a Text::Hyphen using only the learned patterns
result.size_comparison         # learned patterns vs per-word exceptions
```

Candidates are character fragments (optionally anchored to word boundaries)
with position weights, added layer by layer like Liang's patgen: odd levels
vote for a break, even levels vote against one. Every candidate is scored by
the errors it corrects minus the errors it introduces, using the configured
costs. The reported numbers always come from re-evaluating the learned
patterns with the real Text::Hyphen matcher, and with fixed input and
configuration the output is reproducible. If the budget runs out first, the
result keeps the patterns learned so far plus the unresolved counterexamples
(`result.complete?` is false) rather than claiming zero errors.

The `ruby-hyphen-train` command wraps the trainer:

```console
$ ruby-hyphen-train --left 1 --right 1 --budget 100 --seed 42 words.txt
```

where `words.txt` holds one annotated word per line (`rep-re-sen-ta-tion`);
blank lines and lines starting with `#` are ignored.

## Install

gem install text-hyphen

### A Note About Support on Older Rubies

There is no explicit support for any version of Ruby older than 2.6, but none of
the code has been updated and support for version back to 1.8.7 _should_
continue to work.

[TeX::Hyphen]: http://search.cpan.org/author/JANPAZ/TeX-Hyphen-0.140/lib/TeX/Hyphen.pm
[Ruby port]: https://github.com/halostatue/tex-hyphen
[CTAN]: https://www.ctan.org
