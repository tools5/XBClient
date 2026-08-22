package moe.telecom.xbclient

import androidx.compose.foundation.layout.RowScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.ButtonColors
import top.yukonga.miuix.kmp.basic.CardColors
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.basic.TextButtonColors
import top.yukonga.miuix.kmp.squircle.squircleBorder
import top.yukonga.miuix.kmp.theme.Colors
import top.yukonga.miuix.kmp.theme.darkColorScheme
import top.yukonga.miuix.kmp.theme.lightColorScheme

// ============================================================
// 方案 D · 极简高对比 设计令牌（与桌面端同一设计语言）
// 暗色：背景 #0A0A0A / 重要卡面 #0D0D0D / 普通卡透明 + 1px 描边 #262626
// 唯一彩色 = 状态绿（连接状态 / 延迟 / 已选 / 正值）
// ============================================================

/** 卡片圆角 */
internal val XbCardRadius = 10.dp

/** 控件（按钮 / 标签 / 输入类）圆角 */
internal val XbControlRadius = 8.dp

@Immutable
internal data class XbTokens(
    /** 页面背景 */
    val background: Color,
    /** 重要卡面（连接状态卡 / 订阅拦截卡 / 弹窗底） */
    val cardImportant: Color,
    /** 普通卡 1px 描边 */
    val cardBorder: Color,
    /** 列表行 1px 描边 */
    val listRowBorder: Color,
    /** 一级文字 */
    val textPrimary: Color,
    /** 二级强文字 */
    val textStrong: Color,
    /** 弱化文字（摘要） */
    val textMuted: Color,
    /** 最弱文字（占位 / 禁用） */
    val textFaint: Color,
    /** 状态绿（唯一彩色） */
    val accent: Color,
    /** 绿 tag 底 */
    val tagBg: Color,
    /** 绿 tag 文字 */
    val tagText: Color,
    /** 主按钮底（暗色反白 / 亮色反黑） */
    val buttonPrimaryBg: Color,
    /** 主按钮文字 */
    val buttonPrimaryText: Color,
    /** 主按钮禁用底 */
    val buttonPrimaryDisabledBg: Color,
    /** 主按钮禁用文字 */
    val buttonPrimaryDisabledText: Color,
    /** 次按钮 / 中性 tag 描边 */
    val controlBorder: Color,
    /** 错误红（描边式，不做色块） */
    val error: Color,
    /** 警示黄（描边式，不做色块；订单待支付等待办状态） */
    val warning: Color
)

internal val XbDarkTokens = XbTokens(
    background = Color(0xFF0A0A0A),
    cardImportant = Color(0xFF0D0D0D),
    cardBorder = Color(0xFF262626),
    listRowBorder = Color(0xFF222222),
    textPrimary = Color(0xFFFAFAFA),
    textStrong = Color(0xFFEDEDED),
    textMuted = Color(0xFF8F8F8F),
    textFaint = Color(0xFF5C5C5C),
    accent = Color(0xFF4ADE80),
    tagBg = Color(0xFF052E16),
    tagText = Color(0xFF4ADE80),
    buttonPrimaryBg = Color(0xFFEDEDED),
    buttonPrimaryText = Color(0xFF0A0A0A),
    buttonPrimaryDisabledBg = Color(0xFF262626),
    buttonPrimaryDisabledText = Color(0xFF5C5C5C),
    controlBorder = Color(0xFF2E2E2E),
    error = Color(0xFFF87171),
    warning = Color(0xFFFBBF24)
)

internal val XbLightTokens = XbTokens(
    background = Color(0xFFFAFAFA),
    cardImportant = Color(0xFFFFFFFF),
    cardBorder = Color(0xFFE5E5E5),
    listRowBorder = Color(0xFFE5E5E5),
    textPrimary = Color(0xFF0A0A0A),
    textStrong = Color(0xFF0A0A0A),
    textMuted = Color(0xFF525252),
    textFaint = Color(0xFFA3A3A3),
    accent = Color(0xFF16A34A),
    tagBg = Color(0xFFDCFCE7),
    tagText = Color(0xFF166534),
    buttonPrimaryBg = Color(0xFF0A0A0A),
    buttonPrimaryText = Color(0xFFFAFAFA),
    buttonPrimaryDisabledBg = Color(0xFFE5E5E5),
    buttonPrimaryDisabledText = Color(0xFFA3A3A3),
    controlBorder = Color(0xFFE5E5E5),
    error = Color(0xFFDC2626),
    warning = Color(0xFFB45309)
)

internal val LocalXbTokens = staticCompositionLocalOf { XbDarkTokens }

@Composable
internal fun xbTokens(): XbTokens = LocalXbTokens.current

// ============================================================
// Miuix 色板整体重映射（两套令牌都接到 themeMode 机制上）
// ============================================================

internal fun xbDarkColorScheme(): Colors {
    val t = XbDarkTokens
    return darkColorScheme(
        // 强调色 = 状态绿：开关 / 单选 / 复选 / 进度 / 输入框焦点边 / 链接 / “已选”
        primary = t.accent,
        onPrimary = t.tagBg,
        primaryVariant = t.accent,
        onPrimaryVariant = t.textMuted,
        // 错误红：描边式，不做色块
        error = t.error,
        onError = t.background,
        errorContainer = Color(0xFF150A0A),
        onErrorContainer = t.error,
        disabledPrimary = Color(0xFF163B24),
        disabledOnPrimary = t.textFaint,
        disabledPrimaryButton = t.buttonPrimaryDisabledBg,
        disabledOnPrimaryButton = t.buttonPrimaryDisabledText,
        disabledPrimarySlider = Color(0xFF163B24),
        // 绿 tag：奖励图标块 / 我方消息气泡
        primaryContainer = t.tagBg,
        onPrimaryContainer = t.tagText,
        // 中性控件（开关关闭轨道 / 复选未选）
        secondary = t.controlBorder,
        onSecondary = t.textStrong,
        // 次按钮底透明（描边由使用处显式加）
        secondaryVariant = Color.Transparent,
        onSecondaryVariant = t.textStrong,
        disabledSecondary = Color(0xFF1A1A1A),
        disabledOnSecondary = t.textFaint,
        disabledSecondaryVariant = Color.Transparent,
        disabledOnSecondaryVariant = t.textFaint,
        // 输入框底 / 进度条轨道
        secondaryContainer = Color(0xFF1A1A1A),
        onSecondaryContainer = t.textMuted,
        secondaryContainerVariant = Color(0xFF1A1A1A),
        onSecondaryContainerVariant = t.textMuted,
        // 下拉菜单选中项 = 绿
        tertiaryContainer = t.tagBg,
        onTertiaryContainer = t.tagText,
        tertiaryContainerVariant = t.cardBorder,
        // 弹窗 / 底部弹层底 = 重要卡面
        background = t.cardImportant,
        onBackground = t.textPrimary,
        onBackgroundVariant = t.textMuted,
        // Scaffold / 顶栏 / 底栏背景
        surface = t.background,
        onSurface = t.textPrimary,
        surfaceVariant = t.cardImportant,
        onSurfaceSecondary = t.textStrong,
        onSurfaceVariantSummary = t.textMuted,
        onSurfaceVariantActions = t.textFaint,
        disabledOnSurface = t.textFaint,
        // Card 默认底 / 悬浮导航 / 弹出菜单
        surfaceContainer = t.cardImportant,
        onSurfaceContainer = t.textStrong,
        onSurfaceContainerVariant = t.textMuted,
        surfaceContainerHigh = Color(0xFF1A1A1A),
        onSurfaceContainerHigh = t.textMuted,
        surfaceContainerHighest = t.listRowBorder,
        onSurfaceContainerHighest = t.textStrong,
        // 图表网格线 / 分隔线
        outline = t.cardBorder,
        dividerLine = t.listRowBorder,
        windowDimming = Color.Black.copy(alpha = 0.6f),
        sliderKeyPoint = Color(0x4D8F8F8F),
        sliderKeyPointForeground = t.accent,
        sliderBackground = Color(0xFF262626)
    )
}

internal fun xbLightColorScheme(): Colors {
    val t = XbLightTokens
    return lightColorScheme(
        primary = t.accent,
        onPrimary = Color.White,
        primaryVariant = t.accent,
        onPrimaryVariant = t.textMuted,
        error = t.error,
        onError = Color.White,
        errorContainer = Color(0xFFFEF2F2),
        onErrorContainer = Color(0xFF991B1B),
        disabledPrimary = Color(0xFFBBE5C8),
        disabledOnPrimary = Color(0xFFF0FDF4),
        disabledPrimaryButton = t.buttonPrimaryDisabledBg,
        disabledOnPrimaryButton = t.buttonPrimaryDisabledText,
        disabledPrimarySlider = Color(0xFFBBE5C8),
        primaryContainer = t.tagBg,
        onPrimaryContainer = t.tagText,
        secondary = t.controlBorder,
        onSecondary = Color.White,
        secondaryVariant = Color.Transparent,
        onSecondaryVariant = t.textPrimary,
        disabledSecondary = Color(0xFFF0F0F0),
        disabledOnSecondary = Color(0xFFFCFCFC),
        disabledSecondaryVariant = Color.Transparent,
        disabledOnSecondaryVariant = t.textFaint,
        secondaryContainer = Color(0xFFF0F0F0),
        onSecondaryContainer = t.textFaint,
        secondaryContainerVariant = Color(0xFFF0F0F0),
        onSecondaryContainerVariant = t.textFaint,
        tertiaryContainer = t.tagBg,
        onTertiaryContainer = t.accent,
        tertiaryContainerVariant = t.cardBorder,
        background = t.cardImportant,
        onBackground = t.textPrimary,
        onBackgroundVariant = t.textFaint,
        surface = t.background,
        onSurface = t.textPrimary,
        surfaceVariant = t.cardImportant,
        onSurfaceSecondary = t.textMuted,
        onSurfaceVariantSummary = t.textMuted,
        onSurfaceVariantActions = t.textFaint,
        disabledOnSurface = t.textFaint,
        surfaceContainer = t.cardImportant,
        onSurfaceContainer = t.textPrimary,
        onSurfaceContainerVariant = t.textMuted,
        surfaceContainerHigh = Color(0xFFF0F0F0),
        onSurfaceContainerHigh = t.textFaint,
        surfaceContainerHighest = t.cardBorder,
        onSurfaceContainerHighest = t.textPrimary,
        outline = t.cardBorder,
        dividerLine = t.cardBorder,
        windowDimming = Color.Black.copy(alpha = 0.3f),
        sliderKeyPoint = Color(0x4DA3A3A3),
        sliderKeyPointForeground = t.accent,
        sliderBackground = Color(0x0F000000)
    )
}

// ============================================================
// 卡片：重要卡面填充；普通卡透明 + 1px 描边（列表行用 listRow 描边）
// ============================================================

/** 普通卡：透明底，内容用一级文字色 */
@Composable
internal fun xbCardColors(): CardColors {
    val t = xbTokens()
    return CardColors(color = Color.Transparent, contentColor = t.textPrimary)
}

/** 重要卡：#0D0D0D（暗）/ #FFFFFF（亮）填充 */
@Composable
internal fun xbImportantCardColors(): CardColors {
    val t = xbTokens()
    return CardColors(color = t.cardImportant, contentColor = t.textPrimary)
}

/** 普通卡 / 列表行 1px 描边 */
@Composable
internal fun Modifier.xbCardBorder(listRow: Boolean = false, cornerRadius: Dp = XbCardRadius): Modifier {
    val t = xbTokens()
    return squircleBorder(
        width = 1.dp,
        color = if (listRow) t.listRowBorder else t.cardBorder,
        cornerRadius = cornerRadius
    )
}

/** 次按钮 / 中性 tag 描边 */
@Composable
internal fun Modifier.xbControlBorder(cornerRadius: Dp = XbControlRadius): Modifier {
    val t = xbTokens()
    return squircleBorder(width = 1.dp, color = t.controlBorder, cornerRadius = cornerRadius)
}

/** 状态 tag 描边（红 / 灰等描边式 tag，不做色块） */
@Composable
internal fun Modifier.xbOutlineTagBorder(color: Color): Modifier =
    squircleBorder(width = 1.dp, color = color.copy(alpha = 0.5f), cornerRadius = XbControlRadius)

// ============================================================
// 信息伪节点（isInfo）：虚线边框 + 50% 透明
// ============================================================

private fun Modifier.xbDashedBorder(color: Color, cornerRadius: Dp): Modifier = drawBehind {
    val strokeWidth = 1.dp.toPx()
    val half = strokeWidth / 2f
    if (size.width <= strokeWidth || size.height <= strokeWidth) return@drawBehind
    drawRoundRect(
        color = color,
        topLeft = Offset(half, half),
        size = Size(size.width - strokeWidth, size.height - strokeWidth),
        cornerRadius = CornerRadius((cornerRadius.toPx() - half).coerceAtLeast(0f)),
        style = Stroke(
            width = strokeWidth,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()), 0f)
        )
    )
}

/** 信息伪节点行的统一外观：50% 透明 + 虚线描边 */
@Composable
internal fun Modifier.xbInfoFrame(cornerRadius: Dp = XbCardRadius): Modifier {
    val t = xbTokens()
    return alpha(0.5f).xbDashedBorder(t.textMuted, cornerRadius)
}

// ============================================================
// 按钮：主按钮反白（暗）/ 反黑（亮）；次按钮透明底 + 描边
// ============================================================

@Composable
internal fun xbPrimaryButtonColors(): ButtonColors {
    val t = xbTokens()
    return ButtonColors(
        color = t.buttonPrimaryBg,
        disabledColor = t.buttonPrimaryDisabledBg,
        contentColor = t.buttonPrimaryText,
        disabledContentColor = t.buttonPrimaryDisabledText
    )
}

@Composable
internal fun xbSecondaryButtonColors(): ButtonColors {
    val t = xbTokens()
    return ButtonColors(
        color = Color.Transparent,
        disabledColor = Color.Transparent,
        contentColor = t.textStrong,
        disabledContentColor = t.textFaint
    )
}

@Composable
internal fun XbPrimaryButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        cornerRadius = XbControlRadius,
        colors = xbPrimaryButtonColors(),
        content = content
    )
}

@Composable
internal fun XbSecondaryButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit
) {
    Button(
        onClick = onClick,
        modifier = modifier.xbControlBorder(),
        enabled = enabled,
        cornerRadius = XbControlRadius,
        colors = xbSecondaryButtonColors(),
        content = content
    )
}

@Composable
internal fun XbTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    primary: Boolean = false
) {
    val t = xbTokens()
    if (primary) {
        TextButton(
            text = text,
            onClick = onClick,
            modifier = modifier,
            enabled = enabled,
            cornerRadius = XbControlRadius,
            colors = TextButtonColors(
                color = t.buttonPrimaryBg,
                disabledColor = t.buttonPrimaryDisabledBg,
                textColor = t.buttonPrimaryText,
                disabledTextColor = t.buttonPrimaryDisabledText
            )
        )
    } else {
        TextButton(
            text = text,
            onClick = onClick,
            modifier = modifier.xbControlBorder(),
            enabled = enabled,
            cornerRadius = XbControlRadius,
            colors = TextButtonColors(
                color = Color.Transparent,
                disabledColor = Color.Transparent,
                textColor = t.textStrong,
                disabledTextColor = t.textFaint
            )
        )
    }
}
