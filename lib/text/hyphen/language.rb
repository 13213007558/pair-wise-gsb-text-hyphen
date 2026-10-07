# -*- ruby encoding: utf-8 -*-

# Language scaffolding support for Text::Hyphen. Language hyphenation
# patterns are defined as instances of this class—and only this class. This
# is a deliberate "breaking" of Ruby's concept of duck-typing and is
# intended to provide an indication that the patterns have been converted
# from TeX encodings to other encodings (e.g., iso-8859-1 or UTF-8) that are
# more suitable to general text manipulations.
class Text::Hyphen::Language
  class Pattern # :nodoc: all
    attr_reader :tag, :weights, :replacement

    def initialize(tag, weights, replacement = nil)
      @tag = tag
      @weights = weights
      @replacement = replacement
    end

    def digits
      weights.join
    end
  end

  class ExceptionRule # :nodoc: all
    attr_reader :tag, :points, :replacement

    def initialize(tag, points, replacement = nil)
      @tag = tag
      @points = points
      @replacement = replacement
    end

    def weights
      points.map { |point| point ? 1 : 0 }
    end
  end

  WORD_START_RE = %r{^\.} # :nodoc:
  WORD_END_RE = %r{\.$} # :nodoc:
  DIGIT_RE = %r{\d} # :nodoc:
  NONDIGIT_RE = %r{\D} # :nodoc:
  DASH_RE = %r{-} # :nodoc:
  EXCEPTION_DASH0_RE = %r{[^-](?=[^-])} # :nodoc:
  EXCEPTION_DASH1_RE = %r{[^-]-} # :nodoc:
  EXCEPTION_NONUM_RE = %r{[^01]} # :nodoc:
  ZERO_INSERT_RE = %r{(\D)(?=\D)} # :nodoc:
  ZERO_START_RE = %r{^(?=\D)} # :nodoc:

  DEFAULT_ENCODING = if RUBY_VERSION < "1.9.1" # :nodoc:
    "iso-8859-1"
  else
    "utf-8"
  end

  def scan_re # :nodoc:
    if RUBY_VERSION < "1.9.1"
      return %r{.}u if @encoding =~ /utf-?8/i
    end
    %r{.}
  end

  # Splits text into user-perceived characters when Ruby provides Unicode
  # grapheme support. Older Rubies fall back to the language encoding scan.
  def graphemes(value) # :nodoc:
    if value.respond_to?(:grapheme_clusters)
      value.grapheme_clusters
    else
      value.scan(scan_re)
    end
  end

  def diagnostics
    (@pattern_diagnostics || []) + (@exception_diagnostics || [])
  end

  def unescape_replacement(value) # :nodoc:
    value.gsub(%r{\\/}, "/")
  end
  private :unescape_replacement

  def split_replacement_fields(value) # :nodoc:
    fields = []
    field = String.new
    characters = value.each_char.to_a
    characters.each_with_index do |character, index|
      if character == "/" && (index.zero? || characters[index - 1] != "\\")
        fields << field
        field = String.new
      else
        field << character
      end
    end
    fields << field
    fields
  end
  private :split_replacement_fields

  def pattern_weights(rule) # :nodoc:
    weights = [0]
    rule.each_char do |character|
      if character =~ DIGIT_RE
        weights[-1] = character.to_i
      else
        weights << 0
      end
    end
    weights
  end
  private :pattern_weights

  def add_pattern_diagnostic(message) # :nodoc:
    @pattern_diagnostics ||= []
    @pattern_diagnostics << message
    warn message
  end
  private :add_pattern_diagnostic

  def add_exception_diagnostic(message) # :nodoc:
    @exception_diagnostics ||= []
    @exception_diagnostics << message
    warn message
  end
  private :add_exception_diagnostic

  def parse_replacement(rule, source, left, right) # :nodoc:
    source = unescape_replacement(source)
    left = unescape_replacement(left)
    right = unescape_replacement(right)
    target = graphemes(rule.gsub(DIGIT_RE, ""))
    source_parts = graphemes(source)
    occurrences = []

    if source_parts.empty?
      add_pattern_diagnostic("non-standard replacement for #{rule.inspect} has no source interval")
      return nil
    end

    0.upto(target.length - source_parts.length) do |start|
      finish = start + source_parts.length
      occurrences << (start...finish) if target[start...finish] == source_parts
    end

    if occurrences.empty?
      add_pattern_diagnostic("non-standard replacement for #{rule.inspect} crosses a grapheme boundary")
      return nil
    end

    if occurrences.length > 1
      add_pattern_diagnostic("non-standard replacement interval for #{rule.inspect} is ambiguous")
      return nil
    end

    range = occurrences.first
    {
      :source => source,
      :source_start => range.begin,
      :source_end => range.end,
      :left => left,
      :right => right
    }
  end
  private :parse_replacement

  def encoding(enc = nil)
    return @encoding if enc.nil?
    @encoding = enc
  end

  def both
    @patterns[:both]
  end

  def start
    @patterns[:start]
  end

  def stop
    @patterns[:stop]
  end

  def hyphen
    @patterns[:hyphen]
  end

  # The hyphenation patterns for this language. A pattern may be followed by
  # /source/left/right to describe a libhyphen-style non-standard break. The
  # source must align with whole grapheme clusters in the letter pattern.
  def patterns(pats = nil)
    return @patterns if pats.nil?

    @pattern_text = pats.dup
    @pattern_diagnostics = []
    @patterns = { :both => {}, :start => {}, :stop => {}, :hyphen => {} }

    @pattern_text.split($/).each do |line|
      line.gsub(%r{%.*$}, "").split.each do |token|
        next if token.empty?

        start = !token.sub!(WORD_START_RE, "").nil?
        stop = !token.sub!(WORD_END_RE, "").nil?

        rule = token.dup
        replacement_fields = nil
        slash_parts = split_replacement_fields(rule)
        if slash_parts.length == 3
          rule = slash_parts[0]
          source = rule.gsub(DIGIT_RE, "")
          replacement_fields = [source, slash_parts[1], slash_parts[2]]
        elsif slash_parts.length >= 4
          rule = slash_parts[0..-4].join("/")
          replacement_fields = slash_parts[-3..-1]
        end
        rule = unescape_replacement(rule)
        rule_with_digits = rule.dup

        letter_tag = rule_with_digits.gsub(DIGIT_RE, "")
        all_weights = pattern_weights(rule_with_digits)
        replacement = if replacement_fields
          full_replacement = parse_replacement(letter_tag, *replacement_fields)
        end
        tag = replacement ? replacement[:source] : letter_tag
        weights = if replacement
          match_start = letter_tag.index(tag)
          selected_weights = all_weights.slice(match_start, tag.length + 1)
          replacement = replacement.dup
          replacement[:source_start] -= match_start
          replacement[:source_end] -= match_start
          selected_weights
        else
          all_weights
        end

        set = if start && stop
          :both
        elsif start
          :start
        elsif stop
          :stop
        else
          :hyphen
        end

        @patterns[set][tag] = Pattern.new(tag, weights, replacement)
      end
    end

    true
  end

  # Exceptions use dashes to mark allowed break points. A replacement
  # exception appends /left-replacement/right-replacement to the dashed
  # original, e.g. "abc-de/abX/Yzde".
  def exceptions(exc = nil)
    return @exceptions if exc.nil?

    @exception_text = exc.dup
    @exception_diagnostics = []
    @exceptions = {}

    @exception_text.split.each do |word|
      parts = word.split("/")
      if parts.length == 1
        tag = word.gsub(DASH_RE, "")
        value = "0" + word.gsub(EXCEPTION_DASH0_RE, "0").gsub(EXCEPTION_DASH1_RE, "1")
        value.gsub!(EXCEPTION_NONUM_RE, "0")
        points = value.scan(scan_re).map { |digit| digit.to_i.odd? }
        @exceptions[tag] = ExceptionRule.new(tag, points)
        next
      end

      unless parts.length == 3
        add_exception_diagnostic("invalid non-standard exception #{word.inspect}")
        next
      end

      dashed, left, right = parts
      source = dashed.gsub(DASH_RE, "")
      source_parts = graphemes(source)
      points = Array.new(source_parts.length + 1, false)
      source_index = 0
      graphemes(dashed).each do |character|
        if character == "-"
          points[source_index] = true
        else
          source_index += 1
        end
      end

      if source_index != source_parts.length
        add_exception_diagnostic("non-standard exception #{word.inspect} crosses a grapheme boundary")
        next
      end

      replacement = {
        :source => source,
        :source_start => 0,
        :source_end => source_parts.length,
        :left => left,
        :right => right
      }
      @exceptions[source] = ExceptionRule.new(source, points, replacement)
    end

    true
  end

  attr_accessor :left
  attr_accessor :right
  attr_accessor :isocode

  def initialize(language = nil)
    if language.nil?
      encoding DEFAULT_ENCODING
      patterns ""
      exceptions ""
      self.left = 2
      self.right = 2
      self.isocode = nil
    elsif language.is_a? Text::Hyphen::Language
      encoding language.encoding
      patterns language.instance_variable_get(:@pattern_text)
      exceptions language.instance_variable_get(:@exception_text)
      self.left = language.left
      self.right = language.right
      self.isocode = language.isocode
    else
      raise "Languages can only be created from descendants of Text::Hyphen::Language."
    end

    yield self if block_given?
  end

  def self.aliases_for(mapping)
    mapping.each do |language, alias_names|
      unless const_defined? language
        warn "Aliases not created for #{language}; it has not been defined."
        next
      end
      language = const_get(language)

      [alias_names].flatten.each do |alias_name|
        next if const_defined? alias_name
        const_set(alias_name, language)
      end
    end
  end
end
