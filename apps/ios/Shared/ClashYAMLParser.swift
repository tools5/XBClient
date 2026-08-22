import Foundation

// Clash Meta 订阅 YAML 的极简零依赖解析器：只为提取 proxies 数组而生。
// 支持的子集（订阅生成器实际会产出的形态）：
//   * 块映射 / 块序列（含序列项与键同缩进的“零缩进序列”）
//   * 行内 flow 集合 [a, b] / {k: v}，允许跨行（括号未配平时自动续行）
//   * 单引号（'' 转义）与双引号（\ 转义，含 \uXXXX）标量
//   * | 与 > 块标量（多行值），-/+ 收尾指示符
//   * 注释剥离（# 仅在行首或空白后、且不在引号内生效）
//   * true/false/yes/no/on/off 布尔、整数、浮点、null/~
// 不支持锚点/别名的引用展开（&x/*x 仅剥离标记或按原文保留）。
enum ClashYAMLError: LocalizedError {
    case missingProxies
    case proxiesNotArray
    case proxyNotMapping(index: Int)
    case malformed(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingProxies:
            return "订阅内容缺少 proxies 段。"
        case .proxiesNotArray:
            return "订阅的 proxies 段不是数组。"
        case .proxyNotMapping(let index):
            return "订阅 proxies 第 \(index + 1) 项不是键值映射。"
        case .malformed(let line, let reason):
            return "订阅 YAML 第 \(line) 行解析失败：\(reason)"
        }
    }
}

enum ClashYAMLParser {

    /// 从 Clash Meta YAML 文本中解析 proxies 数组，每个代理是一个 [String: Any] 字典。
    /// proxies 为空时返回空数组；缺少 proxies 段或结构非法时抛出 ClashYAMLError。
    static func parseProxies(fromYAML text: String) throws -> [[String: Any]] {
        var parser = Parser(text: text)
        let value = try parser.parseProxiesValue()
        if value is NSNull { return [] }
        guard let array = value as? [Any] else { throw ClashYAMLError.proxiesNotArray }
        var result: [[String: Any]] = []
        result.reserveCapacity(array.count)
        for (index, item) in array.enumerated() {
            guard let dict = item as? [String: Any] else {
                throw ClashYAMLError.proxyNotMapping(index: index)
            }
            result.append(dict)
        }
        return result
    }

    // MARK: - 内部实现

    private struct Parser {
        /// 原始行（已统一换行符）。序列项会把破折号前缀改写成空格，因此是 var。
        var lines: [String]
        var index: Int = 0

        init(text: String) {
            lines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        }

        // MARK: 行工具

        var atEnd: Bool { index >= lines.count }
        var currentIndent: Int { Parser.indent(of: lines[index]) }
        var currentContent: String { Parser.strippedContent(lines[index]) }

        /// 行首空白宽度（tab 记 1 列；YAML 缩进本不该有 tab，宽容处理）。
        static func indent(of line: String) -> Int {
            var count = 0
            for ch in line {
                if ch == " " || ch == "\t" { count += 1 } else { break }
            }
            return count
        }

        /// 剥离注释并去两端空白。# 仅在行首或空白之后、且不在引号内才是注释起点。
        static func strippedContent(_ line: String) -> String {
            var result = ""
            var inSingle = false
            var inDouble = false
            var escaped = false
            var previous: Character? = nil
            for ch in line {
                if inDouble {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { inDouble = false }
                } else if inSingle {
                    if ch == "'" { inSingle = false }
                } else {
                    if ch == "\"" { inDouble = true }
                    else if ch == "'" { inSingle = true }
                    else if ch == "#", previous == nil || previous == " " || previous == "\t" {
                        break
                    }
                }
                result.append(ch)
                previous = ch
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        mutating func skipBlank() {
            while index < lines.count, Parser.strippedContent(lines[index]).isEmpty {
                index += 1
            }
        }

        static func isDashItem(_ content: String) -> Bool {
            content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
        }

        /// 序列项行中“破折号 + 其后空白”的宽度（不含行首缩进），用于计算子块缩进列。
        static func dashPrefixWidth(of rawLine: String) -> Int {
            var width = 0
            var seenDash = false
            for ch in rawLine {
                if !seenDash {
                    if ch == " " || ch == "\t" { continue }
                    if ch == "-" { seenDash = true; width = 1; continue }
                    break
                }
                if ch == " " || ch == "\t" { width += 1 } else { break }
            }
            return width
        }

        /// 块映射的 key 冒号位置：不在引号/flow 括号内、且后随空白或行尾的第一个 ':'。
        static func keyColonIndex(in content: String) -> String.Index? {
            var inSingle = false
            var inDouble = false
            var escaped = false
            var depth = 0
            var i = content.startIndex
            while i < content.endIndex {
                let ch = content[i]
                if inDouble {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { inDouble = false }
                } else if inSingle {
                    if ch == "'" { inSingle = false }
                } else {
                    switch ch {
                    case "\"": inDouble = true
                    case "'": inSingle = true
                    case "[", "{": depth += 1
                    case "]", "}": depth = max(0, depth - 1)
                    case ":":
                        if depth == 0 {
                            let next = content.index(after: i)
                            if next == content.endIndex || content[next] == " " || content[next] == "\t" {
                                return i
                            }
                        }
                    default:
                        break
                    }
                }
                i = content.index(after: i)
            }
            return nil
        }

        static func unquoteKey(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'" else {
                return trimmed
            }
            let chars = Array(trimmed)
            var i = 0
            return (try? parseQuoted(chars, &i, lineNumber: 0)) ?? trimmed
        }

        // MARK: 入口：定位并解析 proxies

        mutating func parseProxiesValue() throws -> Any {
            // 取缩进最浅的 proxies: 行——proxy-groups 里也有 proxies 键，但缩进更深。
            var best: (index: Int, indent: Int)? = nil
            for (i, line) in lines.enumerated() {
                let content = Parser.strippedContent(line)
                if content.isEmpty || content == "---" || content == "..." { continue }
                guard let colon = Parser.keyColonIndex(in: content) else { continue }
                guard Parser.unquoteKey(String(content[..<colon])) == "proxies" else { continue }
                let lineIndent = Parser.indent(of: line)
                if best == nil || lineIndent < best!.indent {
                    best = (i, lineIndent)
                }
            }
            guard let found = best else { throw ClashYAMLError.missingProxies }

            index = found.index
            let content = currentContent
            let keyIndent = found.indent
            guard let colon = Parser.keyColonIndex(in: content) else {
                throw ClashYAMLError.missingProxies
            }
            let rest = String(content[content.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            index += 1

            if !rest.isEmpty {
                // 行内值：一般是 flow 数组 proxies: [{...}, {...}] 或空数组 []
                return try parseInlineValue(rest, lineNumber: found.index + 1)
            }
            skipBlank()
            guard !atEnd else { return NSNull() }
            // 块序列允许与键同缩进（零缩进序列）；更浅则说明 proxies 为空。
            if currentIndent > keyIndent || (currentIndent == keyIndent && Parser.isDashItem(currentContent)) {
                return try parseBlockValue()
            }
            return NSNull()
        }

        // MARK: 块结构

        /// 按当前行形态分派：序列 / 映射 / 单行标量。
        mutating func parseBlockValue() throws -> Any {
            skipBlank()
            guard !atEnd else { return NSNull() }
            let blockIndent = currentIndent
            let content = currentContent
            if Parser.isDashItem(content) {
                return try parseSequence(indent: blockIndent)
            }
            if Parser.keyColonIndex(in: content) != nil {
                return try parseMapping(indent: blockIndent)
            }
            let lineNumber = index + 1
            index += 1
            return try parseInlineValue(content, lineNumber: lineNumber)
        }

        mutating func parseSequence(indent seqIndent: Int) throws -> [Any] {
            var items: [Any] = []
            while true {
                skipBlank()
                guard !atEnd, currentIndent == seqIndent, Parser.isDashItem(currentContent) else { break }
                let lineNumber = index + 1
                let content = currentContent
                if content == "-" {
                    // 值在后续更深的行
                    index += 1
                    skipBlank()
                    if !atEnd, currentIndent > seqIndent {
                        items.append(try parseBlockValue())
                    } else {
                        items.append(NSNull())
                    }
                    continue
                }
                // "- xxx"：剥掉破折号前缀、把当前行改写为子块首行，再按通用块值解析。
                // 子块缩进列 = 序列缩进 + 破折号前缀宽度（即首个内容字符的列号）。
                let rest = String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    items.append(NSNull())
                    continue
                }
                let childIndent = seqIndent + Parser.dashPrefixWidth(of: lines[index])
                lines[index] = String(repeating: " ", count: childIndent) + rest
                if Parser.isDashItem(rest) || Parser.keyColonIndex(in: rest) != nil {
                    items.append(try parseBlockValue())
                } else {
                    index += 1
                    items.append(try parseInlineValue(rest, lineNumber: lineNumber))
                }
            }
            return items
        }

        mutating func parseMapping(indent mapIndent: Int) throws -> [String: Any] {
            var result: [String: Any] = [:]
            while true {
                skipBlank()
                guard !atEnd, currentIndent == mapIndent else { break }
                let content = currentContent
                if Parser.isDashItem(content) { break } // 属于外层序列的下一项
                let lineNumber = index + 1
                guard let colon = Parser.keyColonIndex(in: content) else {
                    throw ClashYAMLError.malformed(line: lineNumber, reason: "期望 key: value 形式")
                }
                let key = Parser.unquoteKey(String(content[..<colon]))
                let rest = String(content[content.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                index += 1

                if rest.isEmpty {
                    // 值是嵌套块：映射必须更深；序列允许与键同缩进。
                    skipBlank()
                    if !atEnd, currentIndent > mapIndent {
                        result[key] = try parseBlockValue()
                    } else if !atEnd, currentIndent == mapIndent, Parser.isDashItem(currentContent) {
                        result[key] = try parseSequence(indent: mapIndent)
                    } else {
                        result[key] = NSNull()
                    }
                    continue
                }
                if let scalar = blockScalarHeader(rest) {
                    result[key] = parseBlockScalar(header: scalar, keyIndent: mapIndent)
                    continue
                }
                result[key] = try parseInlineValue(rest, lineNumber: lineNumber)
            }
            return result
        }

        // MARK: 块标量（| 与 >）

        /// rest 是否是合法块标量头（| 或 > 后仅允许 -/+/缩进数字），是则返回原头部。
        func blockScalarHeader(_ rest: String) -> String? {
            guard let first = rest.first, first == "|" || first == ">" else { return nil }
            for ch in rest.dropFirst() {
                if ch != "-" && ch != "+" && !ch.isNumber { return nil }
            }
            return rest
        }

        mutating func parseBlockScalar(header: String, keyIndent: Int) -> String {
            let folded = header.hasPrefix(">")
            let chomp = header.dropFirst().first(where: { $0 == "-" || $0 == "+" })
            var collected: [String] = []
            var baseIndent: Int? = nil
            while index < lines.count {
                let rawLine = lines[index]
                if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    collected.append("")
                    index += 1
                    continue
                }
                let lineIndent = Parser.indent(of: rawLine)
                if lineIndent <= keyIndent { break }
                if baseIndent == nil { baseIndent = lineIndent }
                let strip = min(baseIndent!, lineIndent)
                collected.append(String(rawLine.dropFirst(strip)))
                index += 1
            }
            while let last = collected.last, last.isEmpty { collected.removeLast() }
            var text = folded ? collected.joined(separator: " ") : collected.joined(separator: "\n")
            // 收尾：默认 clip（保留单个换行），- 去掉，+ 简化为多保留一个。
            if chomp == "+" {
                text += "\n"
            } else if chomp == nil, !text.isEmpty {
                text += "\n"
            }
            return text
        }

        // MARK: 行内值（flow / 引号 / 普通标量）

        mutating func parseInlineValue(_ text: String, lineNumber: Int) throws -> Any {
            let value = Parser.stripAnchorAndTag(text)
            if value.isEmpty { return NSNull() }
            if value.hasPrefix("[") || value.hasPrefix("{") {
                // flow 集合可能跨行：括号不配平就继续拼接后续行。
                var joined = value
                while !Parser.flowBalanced(joined) {
                    guard index < lines.count else {
                        throw ClashYAMLError.malformed(line: lineNumber, reason: "flow 集合括号未闭合")
                    }
                    joined += " " + Parser.strippedContent(lines[index])
                    index += 1
                }
                let chars = Array(joined)
                var i = 0
                return try Parser.parseFlow(chars, &i, lineNumber: lineNumber)
            }
            if value.hasPrefix("\"") || value.hasPrefix("'") {
                let chars = Array(value)
                var i = 0
                return try Parser.parseQuoted(chars, &i, lineNumber: lineNumber)
            }
            return Parser.scalarValue(value)
        }

        /// 仅剥离锚点（&name）与标签（!!str 等）标记，不展开引用。
        static func stripAnchorAndTag(_ text: String) -> String {
            var value = text.trimmingCharacters(in: .whitespaces)
            while let first = value.first, first == "&" || first == "!" {
                guard let space = value.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    return ""
                }
                value = String(value[value.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return value
        }

        static func flowBalanced(_ text: String) -> Bool {
            var inSingle = false
            var inDouble = false
            var escaped = false
            var depth = 0
            for ch in text {
                if inDouble {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { inDouble = false }
                } else if inSingle {
                    if ch == "'" { inSingle = false }
                } else {
                    switch ch {
                    case "\"": inDouble = true
                    case "'": inSingle = true
                    case "[", "{": depth += 1
                    case "]", "}": depth -= 1
                    default: break
                    }
                }
            }
            return depth <= 0 && !inSingle && !inDouble
        }

        // MARK: flow 解析

        static func parseFlow(_ chars: [Character], _ i: inout Int, lineNumber: Int) throws -> Any {
            skipSpaces(chars, &i)
            guard i < chars.count else {
                throw ClashYAMLError.malformed(line: lineNumber, reason: "flow 值为空")
            }
            let ch = chars[i]
            if ch == "[" {
                i += 1
                var array: [Any] = []
                while true {
                    skipSpaces(chars, &i)
                    guard i < chars.count else {
                        throw ClashYAMLError.malformed(line: lineNumber, reason: "flow 数组未闭合")
                    }
                    if chars[i] == "]" { i += 1; break }
                    array.append(try parseFlow(chars, &i, lineNumber: lineNumber))
                    skipSpaces(chars, &i)
                    if i < chars.count, chars[i] == "," { i += 1 }
                }
                return array
            }
            if ch == "{" {
                i += 1
                var dict: [String: Any] = [:]
                while true {
                    skipSpaces(chars, &i)
                    guard i < chars.count else {
                        throw ClashYAMLError.malformed(line: lineNumber, reason: "flow 映射未闭合")
                    }
                    if chars[i] == "}" { i += 1; break }
                    let key: String
                    if chars[i] == "\"" || chars[i] == "'" {
                        key = try parseQuoted(chars, &i, lineNumber: lineNumber)
                    } else {
                        var raw = ""
                        while i < chars.count, chars[i] != ":", chars[i] != "}", chars[i] != "," {
                            raw.append(chars[i])
                            i += 1
                        }
                        key = raw.trimmingCharacters(in: .whitespaces)
                    }
                    skipSpaces(chars, &i)
                    if i < chars.count, chars[i] == ":" {
                        i += 1
                        dict[key] = try parseFlow(chars, &i, lineNumber: lineNumber)
                    } else {
                        dict[key] = NSNull() // {key} 简写
                    }
                    skipSpaces(chars, &i)
                    if i < chars.count, chars[i] == "," { i += 1 }
                }
                return dict
            }
            if ch == "\"" || ch == "'" {
                return try parseQuoted(chars, &i, lineNumber: lineNumber)
            }
            // 普通标量：读到 , ] } 为止
            var raw = ""
            while i < chars.count, chars[i] != ",", chars[i] != "]", chars[i] != "}" {
                raw.append(chars[i])
                i += 1
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw ClashYAMLError.malformed(line: lineNumber, reason: "flow 集合语法错误")
            }
            return scalarValue(trimmed)
        }

        static func skipSpaces(_ chars: [Character], _ i: inout Int) {
            while i < chars.count, chars[i] == " " || chars[i] == "\t" {
                i += 1
            }
        }

        // MARK: 引号标量

        static func parseQuoted(_ chars: [Character], _ i: inout Int, lineNumber: Int) throws -> String {
            let quote = chars[i]
            i += 1
            var result = ""
            if quote == "'" {
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" {
                            result.append("'")
                            i += 2
                            continue
                        }
                        i += 1
                        return result
                    }
                    result.append(ch)
                    i += 1
                }
            } else {
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\\" {
                        i += 1
                        guard i < chars.count else { break }
                        result.append(unescape(chars, &i))
                        continue
                    }
                    if ch == "\"" {
                        i += 1
                        return result
                    }
                    result.append(ch)
                    i += 1
                }
            }
            throw ClashYAMLError.malformed(line: lineNumber, reason: "引号未闭合")
        }

        static func unescape(_ chars: [Character], _ i: inout Int) -> Character {
            let ch = chars[i]
            i += 1
            switch ch {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "0": return "\0"
            case "\\": return "\\"
            case "\"": return "\""
            case "'": return "'"
            case "/": return "/"
            case "u":
                var hex = ""
                var count = 0
                while count < 4, i < chars.count, chars[i].isHexDigit {
                    hex.append(chars[i])
                    i += 1
                    count += 1
                }
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    return Character(scalar)
                }
                return "?"
            default:
                return ch
            }
        }

        // MARK: 普通标量的类型化

        /// 与 SnakeYAML（安卓端使用）的隐式类型保持一致：布尔含 yes/no/on/off 变体。
        static func scalarValue(_ raw: String) -> Any {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return NSNull() }
            switch s {
            case "~", "null", "Null", "NULL":
                return NSNull()
            case "true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON":
                return true
            case "false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF":
                return false
            default:
                break
            }
            if let intValue = Int(s) { return intValue }
            if looksNumeric(s), let doubleValue = Double(s) { return doubleValue }
            return s
        }

        /// 防止 "1.2.3.4"、"inf"、"0x1F" 之类被误判成数字。
        static func looksNumeric(_ s: String) -> Bool {
            var hasDigit = false
            for ch in s {
                if ch.isNumber { hasDigit = true; continue }
                if ch == "+" || ch == "-" || ch == "." || ch == "e" || ch == "E" { continue }
                return false
            }
            return hasDigit
        }
    }
}
