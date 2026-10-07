//
//  SearchEngine.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

import Foundation

struct SearchResult: Equatable {
    let term: String
    let col: Int
    let row: Int
    let size: Int
}

struct SearchSelection {
    let start: Position
    let end: Position
}

final class SearchEngine {
    private let terminal: Terminal
    private let lineCache: SearchLineCache
    private var compiledPattern: String?
    private var compiledCaseSensitive = false
    private var compiledRegex: NSRegularExpression?
    private var deadline: TimeInterval = 0
    private(set) var issue: String?

    func prepare(term: String, options: SearchOptions) -> Bool {
        issue = nil; deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard term.utf8.count <= 4096 else { issue = "搜索内容过长（最多 4 KB）"; return false }
        if options.regex {
            if compiledPattern != term || compiledCaseSensitive != options.caseSensitive || compiledRegex == nil {
                do {
                    compiledRegex = try NSRegularExpression(pattern: term, options: options.caseSensitive ? [] : [.caseInsensitive])
                    compiledPattern = term; compiledCaseSensitive = options.caseSensitive
                } catch { issue = "正则表达式无效：" + error.localizedDescription; return false }
            }
        }
        return true
    }
    func restoreIssue(_ value: String?) { issue = value }
    func releasePattern() { compiledPattern = nil; compiledRegex = nil; issue = nil }
    private var expired: Bool {
        if issue != nil { return true }
        if deadline > 0 && ProcessInfo.processInfo.systemUptime > deadline { issue = "搜索耗时较长，请简化表达式或缩小关键词范围"; return true }
        return false
    }

    init (terminal: Terminal, lineCache: SearchLineCache) {
        self.terminal = terminal
        self.lineCache = lineCache
    }

    func find (term: String, startRow: Int, startCol: Int, searchOptions: SearchOptions? = nil) -> SearchResult? {
        if term.isEmpty {
            return nil
        }
        if startCol > terminal.cols {
            return nil
        }

        lineCache.initLinesCache()

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)

        var result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
        if result == nil {
            let maxRow = terminal.displayBuffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow {
                    if expired { return nil }
                    if terminal.displayBuffer.lines[y].isWrapped { continue }
                    searchPosition.startRow = y
                    searchPosition.startCol = 0
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                    if result != nil {
                        break
                    }
                }
            }
        }
        return result
    }

    func findNextWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }

        lineCache.initLinesCache()

        var startCol = 0
        var startRow = 0
        if let previousSelection {
            if cachedSearchTerm == term {
                startCol = previousSelection.end.col
                startRow = previousSelection.end.row
            } else {
                startCol = previousSelection.start.col
                startRow = previousSelection.start.row
            }
        }

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)
        var result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)

        if result == nil {
            let maxRow = terminal.displayBuffer.lines.count
            if startRow + 1 < maxRow {
                for y in (startRow + 1)..<maxRow {
                    if expired { return nil }
                    if terminal.displayBuffer.lines[y].isWrapped { continue }
                    searchPosition.startRow = y
                    searchPosition.startCol = 0
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                    if result != nil {
                        break
                    }
                }
            }
        }

        if result == nil && startRow != 0 {
            for y in 0..<min(startRow, terminal.displayBuffer.lines.count) {
                if expired { return nil }
                if terminal.displayBuffer.lines[y].isWrapped { continue }
                searchPosition.startRow = y
                searchPosition.startCol = 0
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                if result != nil {
                    break
                }
            }
        }

        if result == nil, let previousSelection {
            searchPosition.startRow = previousSelection.start.row
            searchPosition.startCol = 0
            result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
        }

        return result
    }

    func findPreviousWithSelection (term: String, searchOptions: SearchOptions? = nil, cachedSearchTerm: String?, previousSelection: SearchSelection?) -> SearchResult? {
        if term.isEmpty {
            return nil
        }

        lineCache.initLinesCache()

        let maxRow = terminal.displayBuffer.lines.count - 1
        var startRow = maxRow
        var startCol = terminal.cols
        let isReverseSearch = true

        var searchPosition = SearchPosition(startCol: startCol, startRow: startRow)
        var result: SearchResult?

        if let previousSelection {
            startRow = previousSelection.start.row
            startCol = previousSelection.start.col
            searchPosition.startRow = startRow
            searchPosition.startCol = startCol
            if cachedSearchTerm != term {
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: false)
                if result == nil {
                    startRow = previousSelection.end.row
                    startCol = previousSelection.end.col
                    searchPosition.startRow = startRow
                    searchPosition.startCol = startCol
                }
            }
        }

        if result == nil {
            result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
        }

        if result == nil {
            searchPosition.startCol = max(searchPosition.startCol, terminal.cols)
            if startRow - 1 >= 0 {
                for y in stride(from: startRow - 1, through: 0, by: -1) {
                    if expired { return nil }
                    searchPosition.startRow = y
                    result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                    if result != nil {
                        break
                    }
                }
            }
        }

        if result == nil && startRow != maxRow {
            searchPosition.startCol = terminal.cols
            for y in stride(from: maxRow, through: startRow, by: -1) {
                if expired { return nil }
                searchPosition.startRow = y
                result = findInLine(term: term, searchPosition: &searchPosition, searchOptions: searchOptions, isReverseSearch: isReverseSearch)
                if result != nil {
                    break
                }
            }
        }

        return result
    }

    private func isWholeWord (searchIndex: Int, line: String, term: String) -> Bool {
        let beforeIndex = searchIndex - 1
        let afterIndex = searchIndex + term.count

        let beforeIsBoundary: Bool
        if beforeIndex < 0 {
            beforeIsBoundary = true
        } else {
            beforeIsBoundary = !isWordCharacter(character(at: beforeIndex, in: line) ?? " ")
        }

        let afterIsBoundary: Bool
        if afterIndex >= line.count {
            afterIsBoundary = true
        } else {
            afterIsBoundary = !isWordCharacter(character(at: afterIndex, in: line) ?? " ")
        }

        return beforeIsBoundary && afterIsBoundary
    }

    private func isWordCharacter(_ value: Character) -> Bool {
        value == "_" || value.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }
    }

    private func character (at offset: Int, in line: String) -> Character? {
        guard offset >= 0 && offset < line.count else {
            return nil
        }
        let idx = line.index(line.startIndex, offsetBy: offset)
        return line[idx]
    }

    private func findInLine (term: String, searchPosition: inout SearchPosition, searchOptions: SearchOptions? = nil, isReverseSearch: Bool = false) -> SearchResult? {
        if expired { return nil }
        var row = searchPosition.startRow
        var col = searchPosition.startCol
        let buffer = terminal.displayBuffer

        guard row >= 0 && row < buffer.lines.count else {
            return nil
        }

        if buffer.lines[row].isWrapped {
            if isReverseSearch { searchPosition.startCol += terminal.cols; return nil }
            // A long wrapped line must not recurse once for every screen row.
            while row > 0 && buffer.lines[row].isWrapped { row -= 1; col += terminal.cols }
            searchPosition.startRow = row; searchPosition.startCol = col
        }
        if searchOptions?.regex == true {
            var last = row
            while last + 1 < buffer.lines.count && buffer.lines[last + 1].isWrapped {
                last += 1
                if (last - row + 1) * terminal.cols > 65536 { issue = "正则搜索的单行过长，请使用普通文本搜索"; return nil }
            }
        }

        var cache = lineCache.getLineFromCache(row: row)
        if cache == nil {
            let translated = lineCache.translateBufferLineToStringWithWrap(lineIndex: row, trimRight: true)
            lineCache.setLineInCache(row: row, entry: translated)
            cache = translated
        }

        guard let cacheEntry = cache else {
            return nil
        }

        let stringLine = cacheEntry.lineAsString
        let offsets = cacheEntry.lineOffsets
        let offset = bufferColsToStringOffset(startRow: row, cols: col, offsets: offsets)
        let options = searchOptions ?? SearchOptions()

        var resultIndex: Int?
        var matchTerm = term
        let clampedOffset = min(offset, stringLine.count)
        let offsetIndex = stringLine.index(stringLine.startIndex, offsetBy: clampedOffset)
        if options.regex {
            guard let regex = compiledRegex else { return nil }
            // Match against the entire logical line so ^, $, look-behind and
            // word boundaries do not change when navigation advances its offset.
            regex.enumerateMatches(in: stringLine, options: [.reportProgress, .withoutAnchoringBounds], range: NSRange(stringLine.startIndex..., in: stringLine)) { match, flags, stop in
                if flags.contains(.internalError) { self.issue = "表达式无法完成匹配，请简化表达式"; stop.pointee = true; return }
                if self.expired { stop.pointee = true; return }
                guard let match, match.range.length > 0 else { return }
                let composed = (stringLine as NSString).rangeOfComposedCharacterSequences(for: match.range)
                if options.wholeWord && composed != match.range { return }
                guard let range = Range(composed, in: stringLine) else { return }
                if isReverseSearch {
                    if range.upperBound > offsetIndex { return }
                } else if range.lowerBound < offsetIndex { return }
                let index = stringLine.distance(from: stringLine.startIndex, to: range.lowerBound)
                let text = String(stringLine[range])
                guard !options.wholeWord || self.isWholeWord(searchIndex: index, line: stringLine, term: text) else { return }
                resultIndex = index; matchTerm = text
                if !isReverseSearch { stop.pointee = true }
            }
        } else {
            let compare: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            var range = isReverseSearch ? stringLine.startIndex..<offsetIndex : offsetIndex..<stringLine.endIndex
            while !range.isEmpty && !expired {
                guard let found = stringLine.range(of: term, options: isReverseSearch ? compare.union(.backwards) : compare, range: range) else { break }
                let index = stringLine.distance(from: stringLine.startIndex, to: found.lowerBound)
                let text = String(stringLine[found]) // Case folding may change match length (e.g. ß/SS).
                if !options.wholeWord || isWholeWord(searchIndex: index, line: stringLine, term: text) {
                    resultIndex = index; matchTerm = text; break
                }
                if isReverseSearch { range = range.lowerBound..<found.lowerBound }
                else { range = stringLine.index(after: found.lowerBound)..<range.upperBound }
            }
        }
        guard !expired, let foundIndex = resultIndex else { return nil }

        var startRowOffset = 0
        while startRowOffset < offsets.count - 1 && foundIndex >= offsets[startRowOffset + 1] {
            startRowOffset += 1
        }

        var endRowOffset = startRowOffset
        while endRowOffset < offsets.count - 1 && (foundIndex + matchTerm.count) >= offsets[endRowOffset + 1] {
            endRowOffset += 1
        }

        let startColOffset = foundIndex - offsets[startRowOffset]
        let endColOffset = foundIndex + matchTerm.count - offsets[endRowOffset]
        let startColIndex = stringLengthToBufferSize(row: row + startRowOffset, offset: startColOffset)
        let endColIndex = stringLengthToBufferSize(row: row + endRowOffset, offset: endColOffset)
        let size = endColIndex - startColIndex + terminal.cols * (endRowOffset - startRowOffset)

        return SearchResult(term: matchTerm, col: startColIndex, row: row + startRowOffset, size: size)
    }

    private func stringLengthToBufferSize (row: Int, offset: Int) -> Int {
        let buffer = terminal.displayBuffer
        guard row >= 0 && row < buffer.lines.count else {
            return 0
        }
        if offset == 0 {
            return 0
        }

        let line = buffer.lines[row]
        var adjustedOffset = offset
        var i = 0
        while i < adjustedOffset && i < line.count {
            let cell = line[i]
            if cell.width == 2 {
                let nextIndex = i + 1
                if nextIndex < line.count {
                    let nextCell = line[nextIndex]
                    if nextCell.width == 0 {
                        adjustedOffset += 1
                    }
                }
            }
            i += 1
        }

        return adjustedOffset
    }

    private func bufferColsToStringOffset (startRow: Int, cols: Int, offsets: [Int]) -> Int {
        let buffer = terminal.displayBuffer
        let columns = max(1, terminal.cols)
        let rowOffset = min(max(cols, 0) / columns, max(0, offsets.count - 1))
        let row = startRow + rowOffset
        guard row >= 0 && row < buffer.lines.count else { return 0 }
        let line = buffer.lines[row]
        let remaining = min(max(0, cols - rowOffset * columns), line.count)
        var result = offsets.isEmpty ? 0 : offsets[rowOffset]
        for column in 0..<remaining where line[column].width > 0 { result += 1 }
        return result
    }

}

private struct SearchPosition {
    var startCol: Int
    var startRow: Int
}
