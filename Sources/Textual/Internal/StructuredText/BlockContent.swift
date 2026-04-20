import SwiftUI

// MARK: - Block Resolver Protocol

/// A protocol that allows custom resolution of block types from presentation intents.
///
/// Implement this protocol to add custom block types or override default block rendering
/// behavior. The resolver is checked before falling back to the default block rendering.
///
/// Example:
/// ```swift
/// struct CustomBlockResolver: BlockResolver {
///   func resolve(
///     intent: PresentationIntent.IntentType?,
///     content: AttributedSubstring
///   ) -> AnyView? {
///     // Check for custom mention blocks
///     if content.containsValues(for: [\.mention]) {
///       return AnyView(MentionBlock(content: content))
///     }
///     return nil
///   }
/// }
///
/// StructuredText(markdown)
///   .blockResolver(CustomBlockResolver())
/// ```
@MainActor
public protocol BlockResolver {
  /// Attempts to resolve a block view for the given intent and content.
  ///
  /// - Parameters:
  ///   - intent: The presentation intent type, if any
  ///   - content: The attributed content for this block
  /// - Returns: An `AnyView` if this resolver can handle the block, or `nil` to fall back to default rendering
  func resolve(
    intent: PresentationIntent.IntentType?,
    content: AttributedSubstring
  ) -> AnyView?
}

// MARK: - Environment Key

private struct BlockResolverKey: @MainActor EnvironmentKey {
  @MainActor static let defaultValue: BlockResolver? = nil
}

extension EnvironmentValues {
  @MainActor
  var blockResolver: BlockResolver? {
    get { self[BlockResolverKey.self] }
    set { self[BlockResolverKey.self] = newValue }
  }
}

extension View {
  /// Sets a custom block resolver for structured text rendering.
  ///
  /// Use this modifier to add custom block types or override default block rendering
  /// within the modified view hierarchy.
  ///
  /// - Parameter resolver: The block resolver to use, or `nil` to remove custom resolution
  /// - Returns: A view with the specified block resolver
  public func blockResolver(_ resolver: BlockResolver?) -> some View {
    environment(\.blockResolver, resolver)
  }
}

// MARK: - Block Content View

extension StructuredText {
  struct BlockContent<Content: AttributedStringProtocol>: View {
    private let parent: PresentationIntent.IntentType?
    private let content: Content

    init(parent: PresentationIntent.IntentType? = nil, content: Content) {
      self.parent = parent
      self.content = content
    }

    var body: some View {
      let runs = content.blockRuns(parent: parent)

      BlockVStack {
        ForEach(runs.indices, id: \.self) { index in
          let run = runs[index]
          Block(intent: run.intent, content: content[run.range])
        }
      }
    }
  }
}

// MARK: - Block View

extension StructuredText {
  struct Block: View {
    @Environment(\.blockResolver) private var blockResolver
    
    private let intent: PresentationIntent.IntentType?
    private let content: AttributedSubstring

    init(intent: PresentationIntent.IntentType?, content: AttributedSubstring) {
      self.intent = intent
      self.content = content
    }

    var body: some View {
      // First, try custom block resolver
      if let resolver = blockResolver,
         let customView = resolver.resolve(intent: intent, content: content) {
        customView
      } else {
        // Fall back to default block rendering
        defaultBlock
      }
    }
    
    @ViewBuilder
    private var defaultBlock: some View {
      switch intent?.kind {
      case .paragraph where content.isMathBlock:
        MathBlock(content)
      case .paragraph:
        Paragraph(content)
      case .header(let level):
        Heading(content, level: level)
      case .orderedList:
        OrderedList(intent: intent, content: content)
      case .unorderedList:
        UnorderedList(intent: intent, content: content)
      case .codeBlock(let languageHint) where languageHint?.lowercased() == "math":
        MathCodeBlock(content)
      case .codeBlock(let languageHint):
        CodeBlock(content, languageHint: languageHint)
      case .blockQuote:
        BlockQuote(intent: intent, content: content)
      case .thematicBreak:
        ThematicBreak(content)
      case .table(let columns):
        Table(intent: intent, content: content, columns: columns)
      default:
        Paragraph(content)
      }
    }
  }
}

