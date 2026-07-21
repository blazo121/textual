import Foundation

/// A ``MarkupParser`` implementation backed by Foundation’s Markdown support.
///
/// This parser leverages Foundation’s Markdown support and preserves structure via
/// presentation intents.
///
/// This parser can process its output to expand custom emoji and math expressions into
/// inline attachments.
public struct AttributedStringMarkdownParser: MarkupParser {
  public enum SoftBreakMode: Hashable, Sendable {
    case spaces
    case lineBreaks
  }

  private let baseURL: URL?
  private let options: AttributedString.MarkdownParsingOptions
  private let processor: PatternProcessor
  private let softBreakMode: SoftBreakMode
  // A fully-determined fingerprint of this parser's configuration, or `nil`
  // when the output cannot be safely memoized. Parsing is deterministic in
  // `(configuration, input)`, so identical inputs reparsed with the same
  // configuration can be served from a cache. It is `nil` whenever the
  // configuration is not fully known — custom `options` (opaque and not
  // introspectable) via the public initializer, or any syntax extensions
  // (their replacement closures cannot be fingerprinted).
  private let cacheFingerprint: String?

  public init(
    baseURL: URL?,
    options: AttributedString.MarkdownParsingOptions = .init(),
    syntaxExtensions: [SyntaxExtension] = [],
    softBreakMode: SoftBreakMode = .spaces
  ) {
    // Public initializer: `options` are caller-supplied and cannot be
    // fingerprinted, so memoization is disabled.
    self.init(
      baseURL: baseURL,
      options: options,
      syntaxExtensions: syntaxExtensions,
      softBreakMode: softBreakMode,
      cacheFingerprint: nil
    )
  }

  init(
    baseURL: URL?,
    options: AttributedString.MarkdownParsingOptions,
    syntaxExtensions: [SyntaxExtension],
    softBreakMode: SoftBreakMode,
    cacheFingerprint: String?
  ) {
    self.baseURL = baseURL
    self.options = options
    self.processor = PatternProcessor(syntaxExtensions: syntaxExtensions)
    self.softBreakMode = softBreakMode
    // Syntax extensions carry closures that cannot be fingerprinted, so any
    // extension disables the cache regardless of the requested fingerprint.
    self.cacheFingerprint = syntaxExtensions.isEmpty ? cacheFingerprint : nil
  }

  public func attributedString(for input: String) throws -> AttributedString {
    guard let cacheFingerprint else {
      return try parse(input)
    }

    // `\u{1}` cannot appear in a fingerprint, so it unambiguously separates the
    // configuration prefix from the (exact) input string used as the key.
    let key = cacheFingerprint + "\u{1}" + input as NSString
    if let cached = Self.cache.object(forKey: key) {
      return cached.wrappedValue
    }

    let output = try parse(input)
    Self.cache.setObject(Box(output), forKey: key)
    return output
  }

  private func parse(_ input: String) throws -> AttributedString {
    let output = try processor.expand(
      AttributedString(
        markdown: input,
        including: \.textual,
        options: options,
        baseURL: baseURL
      )
    )

    return switch softBreakMode {
    case .spaces:
      output
    case .lineBreaks:
      preservingSoftBreaks(in: output)
    }
  }

  // Bounded, main-actor-confined memoization of parsed output. `MarkupParser`
  // is `@MainActor`, so no additional synchronization is required.
  @MainActor private static let cache: NSCache<NSString, Box<AttributedString>> = {
    let cache = NSCache<NSString, Box<AttributedString>>()
    cache.countLimit = 64
    return cache
  }()

  private func preservingSoftBreaks(in attributedString: AttributedString) -> AttributedString {
    var output = AttributedString()

    for run in attributedString.runs {
      guard let inlinePresentationIntent = run.inlinePresentationIntent,
        inlinePresentationIntent.contains(.softBreak)
      else {
        output.append(attributedString[run.range])
        continue
      }

      var attributes = run.attributes
      let remainingIntent = inlinePresentationIntent.subtracting(.softBreak)
      attributes.inlinePresentationIntent = remainingIntent.isEmpty ? nil : remainingIntent

      output.append(AttributedString("\n", attributes: attributes))
    }

    return output
  }
}

extension MarkupParser where Self == AttributedStringMarkdownParser {
  /// Creates a Markdown parser configured for inline-only syntax.
  public static func inlineMarkdown(
    baseURL: URL? = nil,
    syntaxExtensions: [AttributedStringMarkdownParser.SyntaxExtension] = []
  ) -> Self {
    // The configuration is fully known here (fixed inline options), so parsing
    // is memoizable. Any syntax extensions still disable the cache internally.
    .init(
      baseURL: baseURL,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
      syntaxExtensions: syntaxExtensions,
      softBreakMode: .spaces,
      cacheFingerprint: "inline|\(baseURL?.absoluteString ?? "")"
    )
  }

  /// Creates a Markdown parser configured for full-document syntax.
  public static func markdown(
    baseURL: URL? = nil,
    syntaxExtensions: [AttributedStringMarkdownParser.SyntaxExtension] = [],
    softBreakMode: AttributedStringMarkdownParser.SoftBreakMode = .spaces
  ) -> Self {
    .init(
      baseURL: baseURL,
      options: .init(),
      syntaxExtensions: syntaxExtensions,
      softBreakMode: softBreakMode,
      cacheFingerprint: "block|\(baseURL?.absoluteString ?? "")|\(softBreakMode)"
    )
  }
}
