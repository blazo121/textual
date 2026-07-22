import Foundation

// MARK: - Overview
//
// `PatternProcessor` applies pattern-based substitutions to an `AttributedString` after parsing.
// It walks each run, skips preformatted content, tokenizes the run’s text, and replaces tokens
// using the first matching syntax extension.
//
// The processor keeps run attributes intact for unchanged text and allows replacement logic to
// inject new attributes (for example, emoji URLs) while preserving the rest of the run’s metadata.
//
// Syntax extensions are opt-in; when no extensions are provided, the input is returned unchanged.

extension AttributedStringMarkdownParser {
  struct PatternProcessor {
    private let syntaxExtensions: [SyntaxExtension]
    private let tokenizer: PatternTokenizer
    // Token type -> the first extension that owns it. Precomputed so the hot
    // loop does a dictionary lookup instead of scanning + allocating per token.
    private let extensionsByTokenType: [PatternTokenizer.TokenType: SyntaxExtension]

    init(syntaxExtensions: [SyntaxExtension]) {
      self.syntaxExtensions = syntaxExtensions
      self.tokenizer = PatternTokenizer(patterns: syntaxExtensions.flatMap(\.patterns))

      var map: [PatternTokenizer.TokenType: SyntaxExtension] = [:]
      for syntaxExtension in syntaxExtensions {
        for pattern in syntaxExtension.patterns where map[pattern.tokenType] == nil {
          map[pattern.tokenType] = syntaxExtension
        }
      }
      self.extensionsByTokenType = map
    }

    func expand(_ attributedString: AttributedString) throws -> AttributedString {
      guard !syntaxExtensions.isEmpty else {
        return attributedString
      }

      // Whole-document fast path: when every pattern declares trigger
      // characters and none occurs anywhere in the text, no replacement is
      // possible, so return the input untouched and skip the rebuild entirely.
      //
      // The scan runs over a flattened `String` rather than
      // `AttributedString.characters`, whose per-element traversal is an order
      // of magnitude slower (it walks attribute storage for every character).
      if let triggers = tokenizer.triggerCharacters {
        let flattened = String(attributedString.characters[...])
        if !flattened.contains(where: triggers.contains) {
          return attributedString
        }
      }

      var output = AttributedString()

      for run in attributedString.runs {
        if run.isPreformatted {
          output.append(attributedString[run.range])
        } else {
          let text = String(attributedString[run.range].characters[...])
          let tokens = try tokenizer.tokenize(text)

          if tokens.count == 1, tokens.first?.type == .text {
            // There are no patterns detected
            output.append(attributedString[run.range])
          } else {
            for token in tokens {
              if let syntaxExtension = extensionsByTokenType[token.type],
                let replacement = syntaxExtension.replace(token, run.attributes)
              {
                output.append(replacement)
              } else {
                // Append the token content without replacing
                output.append(AttributedString(token.content, attributes: run.attributes))
              }
            }
          }
        }
      }

      return output
    }
  }
}

extension Array where Element == AttributedStringMarkdownParser.SyntaxExtension {
  func firstMatching(_ tokenType: PatternTokenizer.TokenType) -> Element? {
    guard tokenType != .text else {
      return nil
    }
    return first {
      $0.patterns.map(\.tokenType).contains(tokenType)
    }
  }
}

extension AttributedString.Runs.Run {
  fileprivate var isPreformatted: Bool {
    if self.inlinePresentationIntent?.isPreformatted ?? false {
      return true
    }

    if self.presentationIntent?.isPreformatted ?? false {
      return true
    }

    return false
  }
}

extension InlinePresentationIntent {
  fileprivate var isPreformatted: Bool {
    contains(.code) || contains(.inlineHTML) || contains(.blockHTML)
  }
}

extension PresentationIntent {
  fileprivate var isPreformatted: Bool {
    components.first?.kind.isPreformatted ?? false
  }
}

extension PresentationIntent.Kind {
  fileprivate var isPreformatted: Bool {
    switch self {
    case .codeBlock:
      return true
    default:
      return false
    }
  }
}
