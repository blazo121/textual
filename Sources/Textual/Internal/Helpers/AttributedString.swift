import Foundation

extension AttributedStringProtocol {
  var isMathBlock: Bool {
    // A math block is a paragraph whose only content is a single block-math
    // attachment. Scan the runs once with early exits instead of building a
    // `Set<AnyAttachment>` (the old `attachments().count == 1` path allocated a
    // set for every paragraph, including the common attachment-free case).
    var unique: AnyAttachment?
    for run in runs {
      guard let attachment = run.attributes.textual.attachment else {
        continue
      }
      if let unique {
        if attachment != unique {
          return false  // more than one distinct attachment
        }
      } else {
        unique = attachment
      }
    }

    guard
      let attachment = unique?.base as? MathAttachment,
      case .block = attachment.displayStyle
    else {
      return false
    }

    return String(self.characters[...])
      .trimmingCharacters(in: .whitespacesAndNewlines) == "\u{FFFC}"
  }

  func attachments() -> Set<AnyAttachment> {
    uniqueValues(for: \.textual.attachment)
  }

  func containsValues<T>(for keyPaths: Set<KeyPath<AttributeContainer, T?>>) -> Bool {
    runs.contains { run in
      keyPaths.first { keyPath in
        run.attributes[keyPath: keyPath] != nil
      } != nil
    }
  }

  func uniqueValues<T: Hashable>(for keyPath: KeyPath<AttributeContainer, T?>) -> Set<T> {
    var values: Set<T> = []
    for run in runs {
      if let value = run.attributes[keyPath: keyPath] {
        values.insert(value)
      }
    }
    return values
  }

  func slugified() -> String {
    String(
      String(characters[...])
        .lowercased()
        .map { $0.isWhitespace ? "-" : $0 }
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
    )
  }
}

// MARK: - Iterable view into blocks
//
// BlockRuns segments an AttributedString into block-level runs based on PresentationIntent
// boundaries. Each BlockRun represents a contiguous range where the block-level intent
// (the intent component immediately before the parent intent in the hierarchy) remains constant.
//
// When the intent changes or becomes nil, a new boundary is recorded. This allows iterating
// over structural blocks (paragraphs, list items, table cells) without reconstructing the
// entire block tree.

extension AttributedStringProtocol {
  func blockRuns(parent: PresentationIntent.IntentType? = nil) -> AttributedString.BlockRuns {
    AttributedString.BlockRuns(attributedString: self, parent: parent)
  }
}

extension AttributedString {
  struct BlockRuns: RandomAccessCollection {
    struct BlockRun: Sendable {
      let intent: PresentationIntent.IntentType?
      let range: Range<AttributedString.Index>
    }

    private struct Boundary {
      let intent: PresentationIntent.IntentType?
      let lowerBound: AttributedString.Index
    }

    typealias Element = BlockRun
    typealias Index = Int

    private let boundaries: [Boundary]
    // Upper bound of the final block (the content's end index). Blocks are
    // contiguous, so every other block's upper bound is the next boundary's
    // lower bound; only the last one needs to be remembered separately.
    private let contentEnd: AttributedString.Index

    init(
      attributedString: some AttributedStringProtocol,
      parent: PresentationIntent.IntentType?
    ) {
      var boundaries: [Boundary] = []
      var lastIntent: PresentationIntent.IntentType?

      // Iterate the runs sequentially (no index re-subscripting) and record a
      // boundary at the first run and wherever the block-level intent changes.
      // Storing each boundary's lower bound lets `subscript` derive block ranges
      // without touching the runs collection again. Runs partition the whole
      // content, so the final block ends at the content's end index.
      for run in attributedString.runs {
        let intent = run.presentationIntent?.intent(before: parent)

        if boundaries.isEmpty || intent != lastIntent {
          boundaries.append(.init(intent: intent, lowerBound: run.range.lowerBound))
          lastIntent = intent
        }
      }

      self.boundaries = boundaries
      self.contentEnd = attributedString.endIndex
    }

    var startIndex: Index { boundaries.startIndex }
    var endIndex: Index { boundaries.endIndex }

    func index(after i: Index) -> Index {
      boundaries.index(after: i)
    }

    func index(before i: Index) -> Index {
      boundaries.index(before: i)
    }

    subscript(position: Index) -> BlockRun {
      let boundary = boundaries[position]
      let upperBound =
        (position + 1 < boundaries.count)
        ? boundaries[position + 1].lowerBound
        : contentEnd

      return BlockRun(intent: boundary.intent, range: boundary.lowerBound..<upperBound)
    }
  }
}

extension PresentationIntent {
  fileprivate func intent(
    before intent: PresentationIntent.IntentType?
  ) -> PresentationIntent.IntentType? {
    guard let intent else {
      return components.last
    }

    guard
      let index = components.firstIndex(of: intent),
      index != components.startIndex
    else {
      return nil
    }

    return components[components.index(before: index)]
  }
}

// MARK: - NSAttributedString

extension NSAttributedString.Key: TextualCompatible {}

extension TextualNamespace where Base == NSAttributedString.Key {
  static var attachment: Base {
    .init(AttributeScopes.TextualAttributes.AttachmentAttribute.name)
  }

  static var presentationIntent: Base {
    .init(AttributeScopes.FoundationAttributes.PresentationIntentAttribute.name)
  }
}
