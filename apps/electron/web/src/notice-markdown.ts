// 公告内容的 Markdown 子集解析：**粗体**、[文字](http(s) url)、行首 #~###### 标题。
// 其他 Markdown 标记原样保留为纯文本。解析前先剥离面板返回的 HTML 标签/实体。

export interface NoticeSpan {
  text: string
  bold: boolean
  href?: string
}

export type NoticeParagraph = NoticeSpan[]

export function parseNoticeMarkdown(content: string): NoticeParagraph[] {
  const text = stripNoticeHtml(content)
  if (!text) return []
  return text.split('\n').map(parseNoticeLine)
}

function stripNoticeHtml(value: string): string {
  return value
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|h[1-6])>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

const HEADING_PATTERN = /^#{1,6}[ \t]+(.*)$/

function parseNoticeLine(line: string): NoticeParagraph {
  const heading = HEADING_PATTERN.exec(line)
  if (heading) return parseNoticeSpans(heading[1].trim(), true)
  return parseNoticeSpans(line, false)
}

function parseNoticeSpans(text: string, bold: boolean): NoticeSpan[] {
  const spans: NoticeSpan[] = []
  let plain = ''
  const flushPlain = () => {
    if (plain) {
      spans.push({ text: plain, bold })
      plain = ''
    }
  }
  let index = 0
  while (index < text.length) {
    if (!bold && text.startsWith('**', index)) {
      const end = text.indexOf('**', index + 2)
      if (end > index + 2) {
        flushPlain()
        spans.push(...parseNoticeSpans(text.slice(index + 2, end), true))
        index = end + 2
        continue
      }
    }
    if (text[index] === '[') {
      const link = matchNoticeLink(text, index)
      if (link) {
        flushPlain()
        spans.push({ text: link.text, bold, href: link.href })
        index = link.end
        continue
      }
    }
    plain += text[index]
    index += 1
  }
  flushPlain()
  return spans
}

interface NoticeLink {
  text: string
  href: string
  end: number
}

function matchNoticeLink(text: string, start: number): NoticeLink | null {
  const labelEnd = text.indexOf(']', start + 1)
  if (labelEnd < 0 || text[labelEnd + 1] !== '(') return null
  const hrefEnd = text.indexOf(')', labelEnd + 2)
  if (hrefEnd < 0) return null
  const label = text.slice(start + 1, labelEnd).trim()
  const href = cleanNoticeHref(text.slice(labelEnd + 2, hrefEnd))
  if (!label || !href) return null
  return { text: label, href, end: hrefEnd + 1 }
}

function cleanNoticeHref(raw: string): string {
  // 面板网页主题用 #eztheme-btn 锚点标记按钮样式，客户端渲染时去掉
  const href = raw.trim().replace(/#eztheme-btn$/i, '')
  if (!/^https?:\/\//i.test(href) || /\s/.test(href)) return ''
  return href
}
