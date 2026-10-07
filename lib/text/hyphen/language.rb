# -*- ruby encoding: utf-8 -*-

# Language scaffolding support for Text::Hyphen. Language hyphenation
# patterns are defined as instances of this class—and only this class. This
# is a deliberate "breaking" of Ruby's concept of duck-typing and is
# intended to provide an indication that the patterns have been converted
# from TeX encodings to other encodings (e.g., iso-8859-1 or UTF-8) that are
# more suitable to general text manipulations.
class Text::Hyphen::Language
  # A non-standard hyphenation replacement. Source graphemes in the
  # original word are replaced by the left-line ending and right-line start.
  class Replacement
    attr_reader :start, :finish, :left, :right

    def initialize(start, finish, left, right)
      @start = start
      @finish = finish
      @left = left
      @right = right
    end

    def ==(other)
      other.is_a?(self.class) && to_a == other.to_a
    end
    alias_method :eql?, :==

    def hash
      [self.class, to_a].hash
    end

    def to_a
      [start, finish, left, right]
    end
  end

  # A weighted TeX pattern and, optionally, its bound replacement.
  class Rule
    attr_reader :tag, :weights, :replacement, :break_point

    def initialize(tag, weights, replacement = nil, break_point = nil)
      @tag = tag
      @weights = weights
      @replacement = replacement
      @break_point = break_point
    end

    def replacement?
      !@replacement.nil?
    end

    def self.graphemes_for(text)
      text.scan(RUBY_VERSION < "1.9.1" ? %r{.} : %r{\X})
    end

    def self.parse_pattern(word, anchor_start, anchor_stop)
      pattern_text, replacement_text = word.split("=", 2)
      pattern_text = pattern_text.dup
      pattern_text.sub!(%r{^\.}, "") if anchor_start
      pattern_text.sub!(%r{\.$}, "") if anchor_stop
      pattern_text.gsub!(%r{(\D)(?=\D)}) { "#{$1}0" }
      pattern_text.sub!(%r{^(?=\D)}, "0")

      tag = pattern_text.gsub(%r{\d}, "")
      weights = pattern_text.gsub(%r{\D}, "")
      return weights if replacement_text.nil?

      breaks = []
      weights.each_char.each_with_index do |digit, index|
        breaks << index if digit.to_i.odd?
      end
      if breaks.length != 1
        raise ArgumentError, "replacement pattern #{word.inspect} must contain one odd break"
      end

      parts = replacement_text.split("/", -1)
      unless parts.length == 2
        raise ArgumentError, "replacement pattern #{word.inspect} must contain left/right text"
      end

      replacement = Replacement.new(0, self.graphemes_for(tag).length, parts[0], parts[1])
      new(tag, weights, replacement, breaks.first)
    end

    def self.from_hash(spec)
      unless spec.is_a?(Hash) && spec.key?(:pattern)
        raise ArgumentError, "replacement rule must contain :pattern"
      end

      pattern_text = spec[:pattern].dup
      anchor_start = pattern_text.start_with?(".")
      anchor_stop = pattern_text.end_with?(".")
      pattern_text.sub!(%r{^\.}, "") if anchor_start
      pattern_text.sub!(%r{\.$}, "") if anchor_stop
      pattern_text.gsub!(%r{(\D)(?=\D)}) { "#{$1}0" }
      pattern_text.sub!(%r{^(?=\D)}, "0")
      tag = pattern_text.gsub(%r{\d}, "")
      weights = pattern_text.gsub(%r{\D}, "")
      graphemes = self.graphemes_for(tag)

      break_point = spec[:break]
      if break_point.nil?
        breaks = []
        weights.each_char.each_with_index do |digit, index|
          breaks << index if digit.to_i.odd?
        end
        break_point = breaks.first if breaks.length == 1
      end

      unless break_point.is_a?(Integer) && weights[break_point] && weights[break_point].to_i.odd?
        raise ArgumentError, "replacement rule #{spec.inspect} has an invalid break"
      end
      unless spec.key?(:left) && spec.key?(:right)
        raise ArgumentError, "replacement rule #{spec.inspect} must contain left and right text"
      end

      start = spec.fetch(:start, 0)
      finish = spec.fetch(:finish, graphemes.length)
      unless start.is_a?(Integer) && finish.is_a?(Integer) && start >= 0 &&
        start <= finish && start <= break_point && break_point <= finish
        raise ArgumentError, "replacement rule #{spec.inspect} has an invalid interval"
      end

      replacement = Replacement.new(start, finish, spec[:left], spec[:right])
      new(tag, weights, replacement, break_point)
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

  # The character scan regular expression to use.
  def scan_re # :nodoc:
    if RUBY_VERSION < "1.9.1"
      return %r{.}u if @encoding =~ /utf-?8/i
    end
    %r{.}
  end

  # The encoding of the hyphenation definitions. The text to be compared
  # must be of the same type.
  def encoding(enc = nil)
    return @encoding if enc.nil?
    @encoding = enc
  end

  # Patterns that match either the beginning or end of a word.
  def both
    @patterns[:both]
  end

  # Patterns that match the beginning of a word.
  def start
    @patterns[:start]
  end

  # Patterns that match the end of a word.
  def stop
    @patterns[:stop]
  end

  # Patterns that hyphenate mid-word.
  def hyphen
    @patterns[:hyphen]
  end

  def pattern_for(hash, key)
    return hash[key] if hash.has_key?(key)
    lookup = @replacement_lookup && @replacement_lookup[hash.object_id]
    lookup && lookup[key]
  end

  def replacement_count(hash)
    lookup = @replacement_lookup && @replacement_lookup[hash.object_id]
    if lookup
      lookup.values.inject(0) { |total, rules| total + rules.length }
    else
      0
    end
  end

  def register_replacement(set, tag, value)
    lookup = @replacement_lookup[@patterns[set].object_id] ||= {}
    lookup[tag] ||= []
    lookup[tag] << value
    nil
  end
  private :register_replacement

  # The hyphenation patterns for this language.
  def patterns(pats = nil)
    return @patterns if pats.nil?

    @pattern_text = pats.dup
    entries = pats.is_a?(String) ? pats.split($/).map { |ln| ln.gsub(%r{%.*$}, "") }.join($/).split : Array(pats)

    @patterns = {
      :both => {},
      :start => {},
      :stop => {},
      :hyphen => {}
    }
    @replacement_lookup = {}

    entries.each do |word|
      items = word.is_a?(String) ? word.gsub(%r{%.*$}, "").split : [word]
      items.flatten.each do |item|
        next if item.nil?

        if item.is_a?(Hash)
          value = Rule.from_hash(item)
          tag = value.tag
          anchor_start = item[:pattern].to_s.start_with?(".")
          anchor_stop = item[:pattern].to_s.end_with?(".")
        else
          word = item
          next if word.empty?
          pattern_for_anchor = word.include?("=") ? word.split("=", 2).first : word
          anchor_start = pattern_for_anchor.start_with?(".")
          anchor_stop = pattern_for_anchor.end_with?(".")

          if word.include?("=")
            value = Rule.parse_pattern(word, anchor_start, anchor_stop)
            tag = value.tag
          else
            word = word.dup
            word.sub!(WORD_START_RE, "") if anchor_start
            word.sub!(WORD_END_RE, "") if anchor_stop
            word.gsub!(ZERO_INSERT_RE) { "#{$1}0" }
            word.gsub!(ZERO_START_RE, "0")
            tag = word.gsub(DIGIT_RE, "")
            value = word.gsub(NONDIGIT_RE, "")
          end
        end

        set = anchor_start && anchor_stop ? :both : anchor_start ? :start : anchor_stop ? :stop : :hyphen

        if value.is_a?(Rule) && value.replacement?
          register_replacement(set, tag, value)
        else
          @patterns[set][tag] = value
        end
      end
    end

    true
  end

  # Exceptions to the hyphenation patterns.
  def exceptions(exc = nil)
    return @exceptions if exc.nil?

    @exception_text = exc.dup
    @exceptions = {}

    entries = exc.is_a?(String) ? exc.split : Array(exc)
    entries.each do |word|
      tag, spec = parse_exception(word)
      @exceptions[tag] = spec
    end

    true
  end

  def parse_exception(word)
    if word.is_a?(Hash)
      word.each do |tag, spec|
        return [tag, build_exception_spec(tag, spec)]
      end
    end

    tag = word.gsub(DASH_RE, "")
    value = "0" + word.gsub(EXCEPTION_DASH0_RE, "0").gsub(EXCEPTION_DASH1_RE, "1")
    value.gsub!(EXCEPTION_NONUM_RE, "0")
    [tag, { :weights => value.scan(grapheme_re).map { |c| c.to_i }, :replacements => {} }]
  end
  private :parse_exception

  def grapheme_re
    RUBY_VERSION < "1.9.1" ? scan_re : %r{\X}
  end
  private :grapheme_re

  def build_exception_spec(tag, spec)
    char_count = tag.scan(scan_re).length
    unless spec.is_a?(Hash) && spec.key?(:breaks)
      raise ArgumentError, "exception #{tag.inspect} must contain :breaks"
    end

    weights = Array.new(char_count + 1, 0)
    Array(spec[:breaks]).each do |point|
      unless point.is_a?(Integer) && point > 0 && point < char_count
        raise ArgumentError, "exception #{tag.inspect} has an invalid break"
      end
      weights[point] = 1
    end

    replacements = {}
    (spec[:replacements] || {}).each do |point, replacement_spec|
      unless replacement_spec.is_a?(Hash) && replacement_spec.key?(:start) &&
        replacement_spec.key?(:finish) && replacement_spec.key?(:left) &&
        replacement_spec.key?(:right)
        raise ArgumentError, "exception #{tag.inspect} has an invalid replacement"
      end
      start = replacement_spec[:start]
      finish = replacement_spec[:finish]
      unless start.is_a?(Integer) && finish.is_a?(Integer) && start >= 0 &&
        finish <= char_count && start <= finish && start <= point && point <= finish
        raise ArgumentError, "exception #{tag.inspect} has an invalid replacement interval"
      end
      replacements[point] = Replacement.new(start, finish, replacement_spec[:left], replacement_spec[:right])
    end

    { :weights => weights, :replacements => replacements }
  end
  private :build_exception_spec

  # No fewer than this number of letters will show up to the left of the
  # hyphen for this language. The default value for this value is 2.
  attr_accessor :left
  # No fewer than this number of letters will show up to the right of the
  # hyphen for this language. The default value for this value is 2.
  attr_accessor :right

  # The ISO language code for this language. Generally only used when there
  # are multiple hyphenation tables available for a language.
  attr_accessor :isocode

  # Creates a new language implementation. If a language object is provided,
  # the default values will be set from the provided language. An exception
  # will be thrown if a value is provided for +language+ that is not an
  # instance of Text::Hyphen::Language.
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

  # Creates language constant aliases for the language.
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
