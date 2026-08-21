package moe.telecom.xbclient

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import top.yukonga.miuix.kmp.basic.Text

// 公告内容的 Markdown 子集解析：**粗体**、[文字](http(s) url)、行首 #~###### 标题。
// 其他 Markdown 标记原样保留为纯文本。解析前先经 plainNoticeText 剥离 HTML 标签/实体。

internal data class NoticeSpan(
    val text: String,
    val bold: Boolean,
    val href: String? = null
)

internal fun parseNoticeMarkdown(content: String): List<List<NoticeSpan>> {
    val text = plainNoticeText(content)
    if (text.isEmpty()) return emptyList()
    return text.split("\n").map(::parseNoticeLine)
}

private val noticeHeadingRegex = Regex("#{1,6}[ \\t]+(.*)")

private fun parseNoticeLine(line: String): List<NoticeSpan> {
    val heading = noticeHeadingRegex.matchEntire(line)
    if (heading != null) return parseNoticeSpans(heading.groupValues[1].trim(), bold = true)
    return parseNoticeSpans(line, bold = false)
}

private fun parseNoticeSpans(text: String, bold: Boolean): List<NoticeSpan> {
    val spans = mutableListOf<NoticeSpan>()
    val plain = StringBuilder()
    fun flushPlain() {
        if (plain.isNotEmpty()) {
            spans.add(NoticeSpan(plain.toString(), bold))
            plain.clear()
        }
    }
    var index = 0
    while (index < text.length) {
        if (!bold && text.startsWith("**", index)) {
            val end = text.indexOf("**", index + 2)
            if (end > index + 2) {
                flushPlain()
                spans.addAll(parseNoticeSpans(text.substring(index + 2, end), bold = true))
                index = end + 2
                continue
            }
        }
        if (text[index] == '[') {
            val link = matchNoticeLink(text, index)
            if (link != null) {
                flushPlain()
                spans.add(NoticeSpan(link.text, bold, link.href))
                index = link.end
                continue
            }
        }
        plain.append(text[index])
        index++
    }
    flushPlain()
    return spans
}

private class NoticeLink(val text: String, val href: String, val end: Int)

private fun matchNoticeLink(text: String, start: Int): NoticeLink? {
    val labelEnd = text.indexOf(']', start + 1)
    if (labelEnd < 0 || labelEnd + 1 >= text.length || text[labelEnd + 1] != '(') return null
    val hrefEnd = text.indexOf(')', labelEnd + 2)
    if (hrefEnd < 0) return null
    val label = text.substring(start + 1, labelEnd).trim()
    val href = cleanNoticeHref(text.substring(labelEnd + 2, hrefEnd))
    if (label.isEmpty() || href.isEmpty()) return null
    return NoticeLink(label, href, hrefEnd + 1)
}

private fun cleanNoticeHref(raw: String): String {
    // 面板网页主题用 #eztheme-btn 锚点标记按钮样式，客户端渲染时去掉
    val href = raw.trim().replace(Regex("#eztheme-btn$", RegexOption.IGNORE_CASE), "")
    if (href.any { it.isWhitespace() }) return ""
    if (!href.startsWith("http://", ignoreCase = true) && !href.startsWith("https://", ignoreCase = true)) return ""
    return href
}

@Composable
internal fun NoticeMarkdownText(
    paragraphs: List<List<NoticeSpan>>,
    modifier: Modifier = Modifier,
    color: Color = Color.Unspecified
) {
    val context = LocalContext.current
    val annotated = remember(paragraphs, context) { noticeAnnotatedString(paragraphs, context) }
    Text(annotated, modifier = modifier, color = color)
}

private fun noticeAnnotatedString(
    paragraphs: List<List<NoticeSpan>>,
    context: Context
): AnnotatedString = buildAnnotatedString {
    paragraphs.forEachIndexed { index, paragraph ->
        if (index > 0) append('\n')
        for (span in paragraph) appendNoticeSpan(span, context)
    }
}

private fun AnnotatedString.Builder.appendNoticeSpan(span: NoticeSpan, context: Context) {
    val href = span.href
    val style = if (span.bold) SpanStyle(fontWeight = FontWeight.Bold) else null
    if (href == null) {
        if (style == null) append(span.text) else withStyle(style) { append(span.text) }
        return
    }
    // styles 留空让 miuix Text 自动套主题主色 + 下划线的链接样式
    val link = LinkAnnotation.Url(
        url = href,
        linkInteractionListener = { BrowserOpener.open(context, href) }
    )
    withLink(link) {
        if (style == null) append(span.text) else withStyle(style) { append(span.text) }
    }
}
