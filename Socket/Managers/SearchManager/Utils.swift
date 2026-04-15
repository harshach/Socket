import Foundation
import SwiftUI

private func hostPortion(_ input: String) -> String {
  let beforePath = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
  let beforeQuery = beforePath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? beforePath
  return beforeQuery
}

private func isLocalhost(_ input: String) -> Bool {
  let host = hostPortion(input).lowercased()
  return host == "localhost" || host.hasPrefix("localhost:")
}

private func isIPAddress(_ host: String) -> Bool {
  let normalizedHost = host.lowercased()

  let bareHost: String = {
    if normalizedHost.hasPrefix("["),
       let closingBracketIndex = normalizedHost.firstIndex(of: "]")
    {
      return String(normalizedHost[normalizedHost.index(after: normalizedHost.startIndex)..<closingBracketIndex])
    }
    if let colonIndex = normalizedHost.lastIndex(of: ":"), normalizedHost[..<colonIndex].contains(".") {
      return String(normalizedHost[..<colonIndex])
    }
    return normalizedHost
  }()

  if bareHost.contains("::") {
    return true
  }

  let parts = bareHost.split(separator: ".")
  guard parts.count == 4 else { return false }

  for part in parts {
    guard let octet = Int(part), (0...255).contains(octet) else {
      return false
    }
  }

  return true
}

public func isValidURL(_ string: String) -> Bool {
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

  if trimmed.isEmpty || trimmed.contains(" ") {
    return false
  }

  guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
    return false
  }

  switch scheme {
  case "http", "https", "ftp":
    if let host = url.host, !host.isEmpty { return true }
    return false
  case "file":
    return url.path.isEmpty == false
  case "chrome-extension", "moz-extension", "webkit-extension", "safari-web-extension":
    return (url.host?.isEmpty == false)
  default:
    return false
  }
}

public func normalizeURL(_ input: String, queryTemplate: String) -> String {
  let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

  if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ||
    trimmed.hasPrefix("file://") || trimmed.hasPrefix("chrome-extension://") ||
    trimmed.hasPrefix("moz-extension://") || trimmed.hasPrefix("webkit-extension://") ||
    trimmed.hasPrefix("safari-web-extension://")
  {
    return trimmed
  }

  if isLocalhost(trimmed) {
    return "http://\(trimmed)"
  }

  if trimmed.contains(".") && !trimmed.contains(" ") {
    if isIPAddress(hostPortion(trimmed)) {
      return "http://\(trimmed)"
    }
    return "https://\(trimmed)"
  }

  let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
  let urlString = String(format: queryTemplate, encoded)
  return urlString
}

public func isLikelyURL(_ text: String) -> Bool {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

  if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
    return true
  }

  if isLocalhost(trimmed) {
    return true
  }

  guard trimmed.contains(".") else { return false }

  if isIPAddress(hostPortion(trimmed)) {
    return true
  }

  return trimmed.contains(".com") || trimmed.contains(".org") ||
    trimmed.contains(".net") || trimmed.contains(".io") ||
    trimmed.contains(".co") || trimmed.contains(".dev")
}

public enum SearchProvider: String, CaseIterable, Identifiable, Codable, Sendable {
  case google
  case duckDuckGo
  case bing
  case brave
  case yahoo
  case perplexity
  case unduck
  case ecosia
  case kagi

  public var id: String { rawValue }

  var displayName: String {
    switch self {
    case .google: return "Google"
    case .duckDuckGo: return "DuckDuckGo"
    case .bing: return "Bing"
    case .brave: return "Brave"
    case .yahoo: return "Yahoo"
    case .perplexity: return "Perplexity"
    case .unduck: return "Unduck"
    case .ecosia: return "Ecosia"
    case .kagi: return "Kagi"
    }
  }

  var host: String {
    switch self {
    case .google: return "www.google.com"
    case .duckDuckGo: return "duckduckgo.com"
    case .bing: return "www.bing.com"
    case .brave: return "search.brave.com"
    case .yahoo: return "search.yahoo.com"
    case .perplexity: return "www.perplexity.ai"
    case .unduck: return "duckduckgo.com"
    case .ecosia: return "www.ecosia.org"
    case .kagi: return "kagi.com"
    }
  }

  var queryTemplate: String {
    switch self {
    case .google:
      return "https://www.google.com/search?q=%@"
    case .duckDuckGo:
      return "https://duckduckgo.com/?q=%@"
    case .bing:
      return "https://www.bing.com/search?q=%@"
    case .brave:
      return "https://search.brave.com/search?q=%@"
    case .yahoo:
      return "https://search.yahoo.com/search?p=%@"
    case .perplexity:
      return "https://www.perplexity.ai/search?q=%@"
    case .unduck:
      return "https://unduck.link?q=%@"
    case .ecosia:
      return "https://www.ecosia.org/search?q=%@"
    case .kagi:
      return "https://kagi.com/search?q=%@"
    }
  }
}
