import Foundation
import PDFKit

actor BookISBNExtractor {
    func extractISBN(from url: URL, maxFrontPages: Int = 10) -> String? {
        extractISBNs(from: url, maxFrontPages: maxFrontPages).first
    }

    func extractISBNs(from url: URL, maxFrontPages: Int = 10) -> [String] {
        guard let document = PDFDocument(url: url) else {
            return []
        }

        var isbns: [String] = []
        let frontPageCount = min(document.pageCount, maxFrontPages)
        for index in 0..<frontPageCount {
            guard let text = document.page(at: index)?.string else { continue }
            appendUnique(findISBNs(in: text), to: &isbns)
        }

        if document.pageCount > maxFrontPages {
            let backStart = max(document.pageCount - 3, maxFrontPages)
            for index in backStart..<document.pageCount {
                guard let text = document.page(at: index)?.string else { continue }
                appendUnique(findISBNs(in: text), to: &isbns)
            }
        }

        return isbns
    }

    func extractISBNs(in text: String) -> [String] {
        findISBNs(in: text)
    }

    func extractLCCNs(from url: URL, maxFrontPages: Int = 10) -> [String] {
        guard let document = PDFDocument(url: url) else {
            return []
        }

        var lccns: [String] = []
        let frontPageCount = min(document.pageCount, maxFrontPages)
        for index in 0..<frontPageCount {
            guard let text = document.page(at: index)?.string else { continue }
            appendUnique(findLCCNs(in: text), to: &lccns)
        }

        return lccns
    }

    private func findISBNs(in text: String) -> [String] {
        let separator = #"[\s\-\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]"#
        let patterns = [
            #"ISBN"# + separator + #"*13[:\s]*[0-9Oo](?:"# + separator + #"*[0-9Oo]){12}"#,
            #"ISBN"# + separator + #"*10[:\s]*[0-9Oo](?:"# + separator + #"*[0-9Oo]){8}"# + separator + #"*[0-9OoXx]"#,
            #"ISBN[:\s]+[0-9OoXx](?:[0-9OoXx\-\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}\s]){8,24}"#,
            #"\b97[89](?:"# + separator + #"*[0-9Oo]){10}"#
        ]

        var isbns: [String] = []
        for pattern in patterns {
            for match in matches(pattern: pattern, in: text) {
                let normalized = normalize(match)
                if isValidISBN(normalized), !isbns.contains(normalized) {
                    isbns.append(normalized)
                }
            }
        }

        return isbns
    }

    private func findLCCNs(in text: String) -> [String] {
        let patterns = [
            #"Library\s+of\s+Congress\s+(?:Control|Catalog(?:ing)?(?:-in-Publication)?)\s+(?:Number|No\.?)[:\s]*([0-9]{2,4}[\s-]?[0-9]{4,8})"#,
            #"\bLCCN[:\s]*([0-9]{2,4}[\s-]?[0-9]{4,8})"#
        ]

        var lccns: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: text) else { continue }
                let normalized = normalizeLCCN(String(text[matchRange]))
                if !normalized.isEmpty, !lccns.contains(normalized) {
                    lccns.append(normalized)
                }
            }
        }

        return lccns
    }

    private func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private func normalize(_ isbn: String) -> String {
        var cleaned = isbn
            .replacingOccurrences(of: #"ISBN[-\s]?1[03][:\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"ISBN[:\s]*"#, with: "", options: .regularExpression)

        cleaned = cleaned.replacingOccurrences(of: #"[Oo]"#, with: "0", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[\s\-\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]"#, with: "", options: .regularExpression)

        if cleaned.hasSuffix("x") {
            cleaned = String(cleaned.dropLast()) + "X"
        }

        return cleaned
    }

    private func normalizeLCCN(_ lccn: String) -> String {
        let cleaned = lccn
            .replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard (8...12).contains(cleaned.count) else {
            return ""
        }

        return cleaned
    }

    private func appendUnique(_ candidates: [String], to isbns: inout [String]) {
        for candidate in candidates where !isbns.contains(candidate) {
            isbns.append(candidate)
        }
    }

    private func isValidISBN(_ isbn: String) -> Bool {
        switch isbn.count {
        case 10: return isValidISBN10(isbn)
        case 13: return isValidISBN13(isbn)
        default: return false
        }
    }

    private func isValidISBN10(_ isbn: String) -> Bool {
        let chars = Array(isbn)
        var sum = 0

        for (index, char) in chars.enumerated() {
            let value: Int
            if char == "X", index == 9 {
                value = 10
            } else if let digit = char.wholeNumberValue {
                value = digit
            } else {
                return false
            }
            sum += value * (10 - index)
        }

        return sum % 11 == 0
    }

    private func isValidISBN13(_ isbn: String) -> Bool {
        let chars = Array(isbn)
        var sum = 0

        for (index, char) in chars.enumerated() {
            guard let digit = char.wholeNumberValue else {
                return false
            }
            sum += digit * (index.isMultiple(of: 2) ? 1 : 3)
        }

        return sum % 10 == 0
    }
}
