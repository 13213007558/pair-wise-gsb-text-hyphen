# -*- ruby encoding: utf-8 -*-

module Text # :nodoc:
end

class Text::Hyphen
  # A usable or unsupported hyphenation opportunity. Position and the
  # replacement interval are character offsets in the original word.
  class Candidate
    attr_reader :position, :start, :finish, :left, :right, :weight, :diagnostic

    def initialize(position, weight, replacement = nil, diagnostic = nil, grapheme_boundary = true)
      @position = position
      @weight = weight
      @diagnostic = diagnostic

      if replacement
        @start = replacement.start
        @finish = replacement.finish
        @left = replacement.left
        @right = replacement.right
      else
        @start = position
        @finish = position
        @left = ""
        @right = ""
      end

      @grapheme_boundary = grapheme_boundary
    end

    def replacement?
      !@left.empty? || !@right.empty?
    end

    def supported?
      @diagnostic.nil?
    end

    def grapheme_boundary?
      @grapheme_boundary
    end

    def parts(word, hyphen = "-")
      raise @diagnostic unless supported?

      if replacement?
        left_part = word[0...start] + self.left
        right_part = self.right + word[finish..-1]
      else
        left_part = word[0...position]
        right_part = word[position..-1]
      end

      [left_part + hyphen, right_part]
    end
    alias_method :split, :parts
  end
end

# An object that knows how to perform hyphenation based on the TeX
# hyphenation algorithm with pattern files. Each object is constructed with
# a specific language's hyphenation patterns.
class Text::Hyphen
  # Resolves a file for cleaner loading from a hyphenation loader file.
  def self.require_real_hyphenation_file(loader) # :nodoc:
    p = File.dirname(loader)
    f = File.basename(loader)
    v = if RUBY_VERSION < "1.9.1"
      "1.8"
    else
      "1.9"
    end
    require File.join(p, v, f)
  end

  VERSION = "1.5.0"

  DEFAULT_MIN_LEFT = 2
  DEFAULT_MIN_RIGHT = 2

  # No fewer than this number of letters will show up to the left of the
  # hyphen. The initial value for this will be specified by the language;
  # setting this value will override the language's defaults.
  attr_accessor :left

  # No fewer than this number of letters will show up to the right of the
  # hyphen. This overrides the default specified in the language.
  attr_accessor :right

  # The name of the language to be used in hyphenating words. This will be a
  # two or three character ISO 639 code, with the two character form being
  # the canonical resource name. This will load the language hyphenation
  # definitions from text/hyphen/language/&lt;code&gt; as a Ruby class. The
  # resource "text/hyphen/language/en_us" defines the language class
  # Text::Hyphen::Language::EN_US. It also defines the secondary forms
  # Text::Hyphen::Language::EN and Text::Hyphen::Language::ENG_US.
  #
  # Minimal transformations will be performed on the language code provided,
  # such that any dashes are converted to underscores (e.g., "en-us" becomes
  # "en_us") and all characters are regularised. Resource names will be
  # downcased and class names will be converted to uppercase (e.g., "Pt" for
  # the Portuguese language becomes "pt" and "PT", respectively).
  #
  # The language may also be specified as an instance of
  # Text::Hyphen::Language.
  #
  # :attr_accessor: language
  attr_reader :language

  def language=(lang) # :nodoc:
    require "text/hyphen/language" unless defined?(Text::Hyphen::Language)
    if lang.is_a? Text::Hyphen::Language
      @iso_language = lang.to_s.split(%r{::}o)[-1].downcase
      @language = lang
    else
      @iso_language = lang.downcase
      load_language
    end
  end

  # Returns the language's ISO 639 ID, e.g., "en_us" or "pt".
  attr_reader :iso_language

  # Creates a hyphenation object with the options requested. The options
  # available are:
  #
  # language::  The language to perform hyphenation with. See #language and
  #             #iso_language.
  # left::      The minimum number of characters to the left of a
  #             hyphenation point. See #left.
  # right::     The minimum number of characters to the right of a
  #             hyphenation point. See #right.
  #
  # The options can be provided either as hashed parameters or set as
  # methods in an initialization block. The following initializations are
  # all equivalent:
  #
  #   hyp = Text::Hyphenate.new(language: "en_us")
  #   hyp = Text::Hyphenate.new { |h| h.language = "en_us" }
  def initialize(options = {}) # :yields self:
    @iso_language = options[:language]
    @left = options[:left]
    @right = options[:right]
    @language = nil

    @cache = {}
    @vcache = {}
    @candidate_cache = {}

    @hyphen = {}
    @begin_hyphen = {}
    @end_hyphen = {}
    @both_hyphen = {}
    @exception = {}

    @first_load = true
    yield self if block_given?
    @first_load = false

    load_language

    @left ||= DEFAULT_MIN_LEFT
    @right ||= DEFAULT_MIN_RIGHT
  end

  # Returns an array of character positions where a word can be hyphenated.
  #
  #   hyp.hyphenate("representation") #=> [3, 5, 8 10]
  #
  # Because hyphenation can be expensive, if the word has been hyphenated
  # previously, it will be returned from a per-instance cache.
  #
  # #hyphenate supports phrase hyphenation:
  #
  #   hyp.hyphenate("This useful library supports phrases and sentences.")
  #   #=> [8, 14, 23, 27, 34, 44]
  #
  # When phrases are hyphenated, each word is processed individually and the
  # result is returned as a single continuous list of hyphenation points.
  # Returns hyphenation candidates, including non-standard replacements.
  # Candidate positions and replacement intervals are character offsets in
  # the original word. Unsupported cross-grapheme replacements and tied,
  # conflicting replacement rules remain present but carry a diagnostic.
  def hyphenate_candidates(word)
    raise ArgumentError, "#hyphenate_candidates does not support phrases" if phrase?(word)
    return @candidate_cache[word] if @candidate_cache.has_key?(word)
    @candidate_cache[word] = analyze_word(word)
  end
  alias_method :candidates, :hyphenate_candidates
  alias_method :hyphenate_with_replacements, :hyphenate_candidates
  alias_method :hyphenation_candidates, :hyphenate_candidates
  alias_method :hyphenate_with_replacement, :hyphenate_candidates

  # Returns diagnostic messages for unsupported or ambiguous candidates.
  def hyphenation_diagnostics(word)
    hyphenate_candidates(word).reject(&:supported?).map(&:diagnostic)
  end
  alias_method :diagnostics, :hyphenation_diagnostics

  def hyphenate(word)
    words = phrase?(word) ? word.downcase.split(/[[:space:]]/) : [word.downcase]

    points = words.map do |item|
      next @cache[item] if @cache.has_key?(item)
      original = phrase?(word) ? item : word
      @cache[item] = hyphenate_candidates(original).select(&:grapheme_boundary?).map { |candidate| candidate.position }
    end

    if points.length > 1
      offset = 0
      result = []

      points.each_with_index do |word, i|
        word.each do |pos|
          result << pos + offset
        end

        offset += words[i].length + 1
      end

      result
    else
      points.flatten
    end
  end

  # Returns a visualization of the hyphenation points.
  #
  #   hyp.visualize('representation') #=> rep-re-sen-ta-tion
  #
  # Any string can be set instead of the default hyphen:
  #
  #   hyp.visualize('example', '&shy;') #=> exam&shy;ple
  #
  # Because hyphenation can be expensive, if the word has been visualised
  # previously, it will be returned from a per-instance cache.
  #
  # #visualise supports phrase hyphenation:
  #
  #   hyp.hyphenate("This useful library supports phrases and sentences.")
  #   #=> This use-ful li-brary sup-port-s phras-es and sen-tences.
  def visualise(word, hyphen = "-")
    return visualise_phrase(word, hyphen) if phrase?(word)
    return @vcache[word] if @vcache.has_key?(word)

    w = word.dup
    s = hyphen.size
    hyphenate(w).each_with_index do |pos, n|
      # Insert the hyphen string at the ported position plus the offset of
      # the last hyphen string inserted.
      w[pos.to_i + (n * s), 0] = hyphen unless pos.zero?
    end
    @vcache[word] = w
  end
  alias_method :visualize, :visualise

  # Clears the per-instance hyphenation and visualization caches.
  def clear_cache!
    @cache.clear
    @vcache.clear
    @candidate_cache.clear
  end

  # This function will hyphenate a word so that the first point is at most
  # +size+ characters.
  #
  # NOTE: if hyphen is set to a string, it will still be counted as one
  # character (since it represents a hyphen)
  #
  # #hyphenate_to does not support phrase hyphenation and will throw an
  # exception if there are spaces.
  def hyphenate_to(word, size, hyphen = "-")
    raise ArgumentError, "#hyphenate_to does not support phrases" if phrase?(word)

    point = hyphenate(word).delete_if { |e| e >= size }.max
    if point.nil?
      [nil, word]
    else
      [word[0...point] + hyphen, word[point..-1]]
    end
  end

  # As #hyphenate_to, but applies the replacement bound to the selected
  # candidate. Unsupported candidates are never selected.
  def hyphenate_to_with_replacements(word, size, hyphen = "-")
    raise ArgumentError, "#hyphenate_to_with_replacements does not support phrases" if phrase?(word)

    candidate = hyphenate_candidates(word).select { |item|
      item.supported? && item.grapheme_boundary? && item.position < size
    }.last
    candidate.nil? ? [nil, word] : candidate.parts(word, hyphen)
  end
  alias_method :hyphenate_to_replacement, :hyphenate_to_with_replacements
  alias_method :hyphenate_to_with_replacement, :hyphenate_to_with_replacements

  # Returns a string describing the structure of the patterns for the
  # language of this hyphenation object.
  def stats
    stats_both = @language.both.size
    stats_start = @language.start.size
    stats_end = @language.stop.size
    stats_hyphens = @language.hyphen.size
    stats_replacements = 0
    [@language.both, @language.start, @language.stop, @language.hyphen].each do |patterns|
      stats_replacements += @language.replacement_count(patterns)
    end
    stats_exceptions = @language.exceptions.size
    stats_total = stats_both + stats_start + stats_end + stats_hyphens + stats_replacements + stats_exceptions

    s = <<-EOS

The language '%s' contains %d total hyphenation patterns.
    % 6d patterns are word start patterns.
    % 6d patterns are word stop patterns.
    % 6d patterns are word start/stop patterns.
    % 6d patterns are normal patterns.
    % 6d patterns are exceptions.

    EOS
    s % [@iso_language, stats_total, stats_start, stats_end, stats_both, stats_hyphens, stats_exceptions]
  end

  GRAPHEME_RE = RUBY_VERSION < "1.9.1" ? %r{.} : %r{\X}

  def analyze_word(word)
    graphemes = word.scan(GRAPHEME_RE)
    transformed = []
    transformed_boundary_at = { 0 => 0 }
    cluster_start_at = []
    cluster_length_at = []
    transformed_offset = 0
    char_offset = 0

    graphemes.each do |grapheme|
      normalized = if "".respond_to?(:unicode_normalize)
        grapheme.unicode_normalize(:nfc)
      else
        grapheme
      end
      normalized_chars = normalized.downcase.scan(@language.scan_re)
      normalized_chars.each do |char|
        transformed << char
        cluster_start_at << char_offset
        cluster_length_at << grapheme.scan(@language.scan_re).length
      end
      transformed_offset += normalized_chars.length
      char_offset += grapheme.scan(@language.scan_re).length
      transformed_boundary_at[transformed_offset] = char_offset
    end

    transformed_word = transformed.join("")
    word_size = transformed.length
    weights = [0] * (word_size + 1)
    replacement_sources = Array.new(word_size + 1) { [] }

    apply_entry = proc do |entry, pos|
      digits = if entry.is_a?(Text::Hyphen::Language::Rule)
        entry.weights
      else
        entry
      end

      digits.scan(@language.scan_re).each_with_index do |digit, index|
        value = digit.to_i
        target = index + pos
        next if value <= 0

        if value > weights[target]
          weights[target] = value
          replacement_sources[target] = []
        end

        if entry.is_a?(Text::Hyphen::Language::Rule) && entry.replacement? &&
          entry.break_point == index && value == weights[target]
          replacement_sources[target] << {
            :start => pos + entry.replacement.start,
            :break => target,
            :finish => pos + entry.replacement.finish,
            :replacement => entry.replacement
          }
        end
      end
    end

    updater = proc do |hash, str, pos|
      entry = @language.pattern_for(hash, str)
      unless entry.nil?
        entry.is_a?(Array) ? entry.each { |item| apply_entry[item, pos] } : apply_entry[entry, pos]
      end
    end

    (0..[word_size - @right, 0].max).each do |pos|
      rest_length = word_size - pos
      (1..rest_length).each do |length|
        substr = transformed[pos, length].join("")
        updater[@language.hyphen, substr, pos]
        updater[@language.start, substr, pos] if pos.zero?
        updater[@language.stop, substr, pos] if length == rest_length
      end
    end
    updater[@language.both, transformed_word, 0]

    exception = @language.exceptions[transformed_word]
    exception_active = !exception.nil?
    if exception
      weights = [0] * (word_size + 1)
      replacement_sources = Array.new(word_size + 1) { [] }
      exception[:weights].each_with_index do |value, index|
        weights[index] = value if index <= word_size
      end
      exception[:replacements].each do |point, replacement|
        next if point > word_size
        weights[point] = 1 unless weights[point].to_i.odd?
        replacement_sources[point] << {
          :exception => true,
          :start => replacement.start,
          :break => point,
          :finish => replacement.finish,
          :replacement => replacement
        }
      end
    end

    candidates = []
    total_graphemes = graphemes.length

    weights.each_with_index do |weight, offset|
      next if weight.to_i.even?
      next if offset.zero? || offset >= word_size

      sources = replacement_sources[offset]
      distinct_sources = sources.uniq { |source| source_replacement(source) }
      position = transformed_boundary_at[offset]
      grapheme_boundary = !position.nil?
      diagnostic = nil
      replacement = nil

      if position.nil?
        next if sources.empty?
        position = cluster_start_at[offset]
        diagnostic = "replacement crosses a grapheme cluster boundary"
      end

      unless exception_active
        grapheme_index = grapheme_index_for_offset(offset, transformed_boundary_at)
        next if grapheme_index && (grapheme_index < @left || total_graphemes - grapheme_index < @right)
      end

      if distinct_sources.length > 1
        diagnostic ||= "overlapping replacement rules provide conflicting alternatives at position #{position}"
      end

      source = distinct_sources.first
      if source
        raw = source_replacement(source)
        start = transformed_boundary_at[source[:start]]
        finish = transformed_boundary_at[source[:finish]]

        if source[:exception]
          start = cluster_start_at[source[:start].to_i] || 0
          finish_index = source[:finish].to_i - 1
          finish_index = [finish_index, word_size - 1].min
          finish = word_size.zero? ? word.length : cluster_start_at[finish_index] + cluster_length_at[finish_index]
          if transformed_boundary_at[source[:start]].nil? || transformed_boundary_at[source[:finish]].nil?
            diagnostic ||= "replacement crosses a grapheme cluster boundary"
          end
        elsif start.nil? || finish.nil?
          start = cluster_start_at[source[:start].to_i] || 0
          finish_index = source[:finish].to_i - 1
          finish_index = [finish_index, word_size - 1].min
          finish = word_size.zero? ? word.length : cluster_start_at[finish_index] + cluster_length_at[finish_index]
          diagnostic ||= "replacement crosses a grapheme cluster boundary"
        end

        left_text = replacement_case(raw.left, word[start...finish], true)
        right_text = replacement_case(raw.right, word[start...finish], false)
        replacement = Text::Hyphen::Language::Replacement.new(start, finish, left_text, right_text)
      elsif diagnostic
        replacement = Text::Hyphen::Language::Replacement.new(position, position, "", "")
      end

      candidates << Candidate.new(position, weight, replacement, diagnostic, grapheme_boundary)
    end

    candidates
  end
  private :analyze_word

  def grapheme_index_for_offset(offset, boundary_at)
    boundaries = boundary_at.keys.select { |boundary| boundary <= offset }.sort
    boundaries.empty? ? nil : boundaries.length - 1
  end
  private :grapheme_index_for_offset

  def source_replacement(source)
    source[:replacement]
  end
  private :source_replacement

  def replacement_case(text, source, left_side)
    return text if text.nil? || text.empty? || source.nil? || source.empty?

    if source =~ /[[:alpha:]]/ && source == source.upcase
      text.upcase
    elsif left_side && source[0] =~ %r{\p{Upper}}
      graphemes = text.scan(GRAPHEME_RE)
      graphemes.first.upcase + graphemes[1..-1].to_a.join("")
    else
      text
    end
  end
  private :replacement_case

  def make_result_list(res)
    r = []
    res.each_with_index { |c, i| r << i * (c.to_i % 2) }
    r.reject { |i| i.to_i == 0 }
  end
  private :make_result_list

  def load_language
    return if @first_load

    @iso_language ||= "en_us"

    unless @language
      require "text/hyphen/language/#{@iso_language}"
      @language = Text::Hyphen::Language.const_get(@iso_language.upcase)
      @iso_language = @language.isocode if @language.isocode
    end

    @left ||= @language.left
    @right ||= @language.right

    @iso_language
  end
  private :load_language

  def split_phrase(phrase)
    phrase.split(/[[:space:]]+/)
  end
  private :split_phrase

  def visualise_phrase(phrase, hyphen)
    split_phrase(phrase).map { |word| visualise(word, hyphen) }.join(" ")
  end
  private :visualise_phrase

  def phrase?(input)
    /[^[:space:]][[:space:]][^[:space:]]/.match?(input)
  end
  private :phrase?
end

# vim: syntax=ruby
