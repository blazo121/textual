import SwiftUI

public struct LinkAttribute: TextAttribute {
  var url: URL

  public init(_ url: URL) {
    self.url = url
  }
}

extension Text.Layout.Run {
  var url: URL? {
    self[LinkAttribute.self]?.url
  }
}
