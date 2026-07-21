import Foundation

// MARK: - Overview
//
// `PatternTokenizer` scans source text and splits it into tokens based on a small set of
// regex patterns.
//
// It’s designed for postprocessing steps that need to rewrite specific constructs (like emoji
// shortcodes) while leaving everything else untouched. Each pattern is applied as a prefix match
// at the current cursor position, which keeps the tokenizer simple and predictable.
//
// This tokenizer is intentionally conservative: patterns are opt-in and processing is linear. If
// no patterns are provided, the input is returned as a single `.text` token.

public struct PatternTokenizer {
  private let patterns: [Pattern]

  // Union of the trigger characters across all patterns, used as a cheap
  // prefilter: a match is impossible unless the input contains at least one
  // trigger. Only enabled when *every* pattern declares triggers — otherwise a
  // pattern with no declared trigger could match anywhere and the prefilter
  // would be unsound, so it is disabled (`nil`).
  private let triggers: Set<Character>?

  /// The union of trigger characters when every pattern declares them, else
  /// `nil`. Callers can use this to short-circuit whole inputs that contain no
  /// trigger (see `PatternProcessor`).
  var triggerCharacters: Set<Character>? { triggers }

  init(patterns: [Pattern]) {
    self.patterns = patterns
    if !patterns.isEmpty, patterns.allSatisfy({ !$0.triggers.isEmpty }) {
      self.triggers = patterns.reduce(into: Set<Character>()) { $0.formUnion($1.triggers) }
    } else {
      self.triggers = nil
    }
  }

  func tokenize(_ input: String) throws -> [Token] {
    guard !patterns.isEmpty else {
      return [.init(type: .text, content: input)]
    }

    // Prefilter: if no trigger character occurs in the input, no pattern can
    // match, so skip the regex scan entirely. This is the common case for
    // prose runs that contain neither `:` (emoji) nor `$` (math).
    if let triggers, !input.contains(where: triggers.contains) {
      return [.init(type: .text, content: input)]
    }

    var tokens: [Token] = []
    var cursor = input.startIndex

    while cursor < input.endIndex {
      // Find the earliest match among all patterns in the remaining slice.
      //
      // This preserves the original priority semantics: at a given start
      // position, the first pattern (lowest index) wins. Because we iterate
      // patterns in order and only replace `best` on a *strictly* earlier
      // start, ties at the same position keep the lower-indexed pattern.
      let slice = input[cursor...]
      var best:
        (
          start: String.Index, patternIndex: Int, full: Substring, captured: Substring,
          upper: String.Index
        )?

      for (index, pattern) in patterns.enumerated() {
        guard let match = try pattern.regex.firstMatch(in: slice) else {
          continue
        }
        let start = match.range.lowerBound
        if best == nil || start < best!.start {
          best = (start, index, match.output.0, match.output.1, match.range.upperBound)
        }
        // The earliest possible start is the cursor itself; nothing a
        // later (lower-priority) pattern finds can beat it.
        if best!.start == cursor {
          break
        }
      }

      guard let match = best else {
        // No pattern matches anywhere in the remaining slice: the rest is text.
        appendText(&tokens, String(slice))
        break
      }

      // Emit the gap before the match as a single text token.
      if cursor < match.start {
        appendText(&tokens, String(input[cursor..<match.start]))
      }

      tokens.append(
        .init(
          type: patterns[match.patternIndex].tokenType,
          content: String(match.full),
          capturedContent: String(match.captured)
        )
      )

      // Guard against a hypothetical zero-width match to avoid an infinite loop.
      cursor = match.upper > match.start ? match.upper : input.index(after: match.start)
    }

    return tokens
  }

  private func appendText(_ tokens: inout [Token], _ content: String) {
    if let last = tokens.indices.last, tokens[last].type == .text {
      tokens[last].content += content
    } else {
      tokens.append(.init(type: .text, content: content))
    }
  }
}

extension PatternTokenizer {
  public struct Pattern {
    public init(regex: Regex<(Substring, Substring)>, tokenType: PatternTokenizer.TokenType) {
      self.init(regex: regex, tokenType: tokenType, triggers: [])
    }

    /// Creates a pattern with a set of *trigger* characters: characters without
    /// which the regex cannot possibly match. When every pattern in a tokenizer
    /// declares triggers, the tokenizer skips the regex scan for any input that
    /// contains none of them. Pass an empty set (the default) to disable this
    /// prefilter for the pattern.
    public init(
      regex: Regex<(Substring, Substring)>,
      tokenType: PatternTokenizer.TokenType,
      triggers: Set<Character>
    ) {
      self.regex = regex
      self.tokenType = tokenType
      self.triggers = triggers
    }

    public let regex: Regex<(Substring, Substring)>
    public let tokenType: TokenType
    public let triggers: Set<Character>
  }
}

extension PatternTokenizer.Pattern {
  static var emoji: Self {
    .init(regex: /:([a-zA-Z0-9_+-]+):/, tokenType: .emoji, triggers: [":"])
  }

  static var mathBlock: Self {
    .init(regex: /(?s)\$\$(.+?)\$\$/, tokenType: .mathBlock, triggers: ["$"])
  }

  static var mathInline: Self {
    .init(regex: /\$(?!\$)((?:\\\$|[^$\n])+)\$/, tokenType: .mathInline, triggers: ["$"])
  }
}

extension PatternTokenizer {
  public struct Token: Hashable, Sendable {
    public let type: TokenType
    public var content: String
    public var capturedContent: String?
  }
}

extension PatternTokenizer {
  public struct TokenType: Hashable, RawRepresentable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
      self.rawValue = value
    }
  }
}

extension PatternTokenizer.TokenType {
  static let text: Self = "text"
  static let emoji: Self = "emoji"
  static let mathBlock: Self = "mathBlock"
  static let mathInline: Self = "mathInline"
}
