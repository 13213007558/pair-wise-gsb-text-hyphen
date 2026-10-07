# -*- ruby encoding: utf-8 -*-

module Text # :nodoc:
end

# An object that knows how to perform hyphenation based on the TeX
# hyphenation algorithm with pattern files. Each object is constructed with
# a specific language's hyphenation patterns.
class Text::Hyphen
  Hyphenation = Struct.new(:word, :points, :candidates, :diagnostics) do
    def candidate_at(position)
      candidates.detect { |candidate| candidate.position == position }
    end

    def split(position = nil, hyphen = "-")
      target = position.nil? ? candidates.first : candidate_at(position)
      target ? target.split(word, hyphen) : [nil, word]
    end
  end
  HyphenationResult = Hyphenation

  HyphenationCandidate = Struct.new(
    :position,
    :replacement_start,
    :replacement_end,
    :left_replacement,
    :right_replacement,
    :rule
  ) do
    def replacement?
      !replacement_start.nil?
    end

    def source_range
      replacement_start.nil? ? nil : (replacement_start...replacement_end)
    end
    alias_method :range, :source_range

    def source
      rule
    end

    def left
      left_replacement
    end

    def right
      right_replacement
    end

    def start
      replacement_start
    end

    def stop
      replacement_end
    end

    def split(word, hyphen = "-")
      letters = graphemes(word)
      if replacement_start.nil?
        return [letters[0...position].join + hyphen, letters[position..-1].join]
      end

      left_part = letters[0...replacement_start].join + left_replacement.to_s + hyphen
      right_part = right_replacement.to_s + (letters[replacement_end..-1] || []).join
      [left_part, right_part]
    end
    alias_method :apply, :split

    private

    def graphemes(value)
      if value.respond_to?(:grapheme_clusters)
        value.grapheme_clusters
      else
        value.scan(%r{.}u)
      end
    end
  end
  Candidate = HyphenationCandidate

  VERSION = "1.5.0"

  DEFAULT_MIN_LEFT = 2
  DEFAULT_MIN_RIGHT = 2

  attr_accessor :left
  attr_accessor :right
  attr_reader :language
  attr_reader :iso_language

  def self.require_real_hyphenation_file(loader) # :nodoc:
    path = File.dirname(loader)
    file = File.basename(loader)
    version = RUBY_VERSION < "1.9.1" ? "1.8" : "1.9"
    require File.join(path, version, file)
  end

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

  def initialize(options = {}) # :yields self:
    @iso_language = options[:language]
    @left = options[:left]
    @right = options[:right]
    @language = nil

    @cache = {}
    @vcache = {}
    @result_cache = {}

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

  # Returns an array of grapheme positions where a word can be hyphenated.
  def hyphenate(word)
    hyphenation(word).points
  end

  # Returns detailed hyphenation candidates, including non-standard source
  # intervals and replacement fragments. All positions refer to the original
  # word rather than its lower-cased or normalized form.
  def hyphenation(word)
    results = hyphenation_results(word)
    return results.first if results.length == 1

    points = []
    candidates = []
    offset = 0

    results.each do |result|
      points.concat(result.points.map { |point| point + offset })
      result.candidates.each do |candidate|
        moved = candidate.dup
        moved.position += offset
        unless moved.replacement_start.nil?
          moved.replacement_start += offset
          moved.replacement_end += offset
        end
        candidates << moved
      end
      offset += graphemes(result.word).length + 1
    end

    Hyphenation.new(word, points, candidates, results.flat_map(&:diagnostics).uniq)
  end
  alias_method :hyphenate_with_replacements, :hyphenation

  def visualise(word, hyphen = "-")
    return visualise_phrase(word, hyphen) if phrase?(word)
    return @vcache[word] if @vcache.has_key?(word)

    @vcache[word] = hyphenation(word).candidates.reverse.reduce(word.dup) do |result, candidate|
      candidate.split(result, hyphen).join
    end
  end
  alias_method :visualize, :visualise

  def clear_cache!
    @cache.clear
    @vcache.clear
    @result_cache.clear
  end

  def hyphenate_to(word, size, hyphen = "-")
    raise ArgumentError, "#hyphenate_to does not support phrases" if phrase?(word)

    result = hyphenation(word)
    candidate = result.candidates.select { |item| item.position < size }.last
    candidate ? candidate.split(word, hyphen) : [nil, word]
  end

  def stats
    stats_both = @language.both.size
    stats_start = @language.start.size
    stats_end = @language.stop.size
    stats_hyphens = @language.hyphen.size
    stats_exceptions = @language.exceptions.size
    stats_total = stats_both + stats_start + stats_end + stats_hyphens + stats_exceptions

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

  private

  def hyphenation_results(input)
    words = phrase?(input) ? split_phrase(input) : [input]
    words.map { |word| hyphenate_word(word) }
  end

  def hyphenate_word(word)
    return @result_cache[word] if @result_cache.key?(word)

    original = graphemes(word)
    letters = original.map { |letter| letter.downcase }
    normalized = letters.join
    word_size = letters.length
    weights = [0] * (word_size + 1)
    winners = [nil] * (word_size + 1)
    ambiguous = [nil] * (word_size + 1)
    right_stop = word_size

    apply_pattern = proc do |pattern, position|
      pattern.weights.each_with_index do |weight, offset|
        slot = position + offset
        current = winners[slot]

        if weight > weights[slot]
          weights[slot] = weight
          winners[slot] = { :pattern => pattern, :position => position }
          ambiguous[slot] = nil
        elsif weight == weights[slot] && current && (replacement_pattern?(pattern) || replacement_pattern?(current[:pattern]))
          ambiguous[slot] = [current[:pattern], pattern]
        end
      end
    end

    if (exception = @language.exceptions[normalized])
      exception.weights.each_with_index do |weight, slot|
        weights[slot] = weight
        winners[slot] = { :pattern => exception, :position => 0, :exception => true }
        ambiguous[slot] = nil
      end
    else
      (0..right_stop).each do |position|
        rest_length = word_size - position
        (1..rest_length).each do |length|
          substring = letters[position, length].join("")
          pattern = @language.hyphen[substring]
          apply_pattern[pattern, position] if pattern

          if position.zero?
            pattern = @language.start[substring]
            apply_pattern[pattern, position] if pattern
          end

          if length == rest_length
            pattern = @language.stop[substring]
            apply_pattern[pattern, position] if pattern
          end
        end
      end

      pattern = @language.both[normalized]
      apply_pattern[pattern, 0] if pattern
    end

    candidates = []
    diagnostics = @language.respond_to?(:diagnostics) ? @language.diagnostics.dup : []

    (1...word_size).each do |position|
      next unless weights[position].odd?
      next if position <= @left || word_size - position < @right

      if ambiguous[position]
        tags = ambiguous[position].map { |pattern| pattern.tag.inspect }.join(", ")
        message = "overlapping non-standard replacement at position #{position}: #{tags}"
        diagnostics << message
      end

      replacement = ambiguous[position] ? nil : replacement_for(word, winners[position], position, diagnostics)
      candidates << make_candidate(position, replacement)
    end

    result = Hyphenation.new(word, candidates.map(&:position), candidates, diagnostics.uniq)
    @result_cache[word] = result
    @cache[normalized] = result.points
    result
  end

  def replacement_pattern?(pattern)
    pattern.respond_to?(:replacement) && !pattern.replacement.nil?
  end

  def replacement_for(word, winner, point, diagnostics)
    return nil if winner.nil?

    pattern = winner[:pattern]
    replacement = pattern.respond_to?(:replacement) ? pattern.replacement : nil
    return nil if replacement.nil?

    start = winner[:position] + replacement[:source_start].to_i
    finish = winner[:position] + replacement[:source_end].to_i

    unless (start..finish).cover?(point)
      diagnostics << "replacement from #{pattern.tag.inspect} is not bound to position #{point}"
      return nil
    end

    source = graphemes(word)[start...finish].join
    adjusted = replacement.dup
    adjusted[:source] = source
    adjusted[:source_start] = start
    adjusted[:source_end] = finish
    adjust_replacement_case(adjusted, source)
  end

  def adjust_replacement_case(replacement, source)
    if source =~ /[[:alpha:]]/ && source == source.upcase
      replacement[:left] = replacement[:left].to_s.upcase
      replacement[:right] = replacement[:right].to_s.upcase
    elsif source =~ /\A[[:upper:]]/
      left_parts = graphemes(replacement[:left].to_s)
      replacement[:left] = if left_parts.empty?
        replacement[:left].to_s
      else
        left_parts[0].upcase + left_parts[1..-1].join
      end
      replacement[:right] = replacement[:right].to_s.downcase
    end
    replacement
  end

  def make_candidate(position, replacement = nil)
    HyphenationCandidate.new(
      position,
      replacement && replacement[:source_start],
      replacement && replacement[:source_end],
      replacement && replacement[:left],
      replacement && replacement[:right],
      replacement && replacement[:source]
    )
  end

  def graphemes(value)
    @language.graphemes(value)
  end

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

  def split_phrase(phrase)
    phrase.split(/[[:space:]]+/)
  end

  def visualise_phrase(phrase, hyphen)
    split_phrase(phrase).map { |word| visualise(word, hyphen) }.join(" ")
  end

  def phrase?(input)
    /[^[:space:]][[:space:]][^[:space:]]/.match?(input)
  end
end

# vim: syntax=ruby
