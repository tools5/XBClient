package moe.telecom.xbclient

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.LinearProgressIndicator
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.preference.RadioButtonPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme

@Composable
internal fun HomeScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    val context = LocalContext.current
    // 选中索引可能指向订阅里的信息条目（“剩余流量”等公告伪节点），首页展示校正为真实节点
    val selectedIndex = resolveSelectedNodeIndex(state.anyTlsNodes, state.selectedNodeIndex)
    val selectedNode = state.anyTlsNodes.getOrNull(selectedIndex)?.takeIf { it.connectSupported && !it.isInfo }
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    val latencySamples = remember { mutableStateListOf<Int>() }
    val uploadSpeedSamples = remember { mutableStateListOf<Long>() }
    val downloadSpeedSamples = remember { mutableStateListOf<Long>() }
    LaunchedEffect(state.vpnRequested) {
        if (!state.vpnRequested) {
            uploadSpeedSamples.clear()
            downloadSpeedSamples.clear()
            return@LaunchedEffect
        }
        var (lastRx, lastTx) = viewModel.refreshVpnSessionStats()
        var lastAt = System.currentTimeMillis()
        while (state.vpnRequested) {
            delay(1000)
            now = System.currentTimeMillis()
            val (rx, tx) = viewModel.refreshVpnSessionStats()
            val elapsed = (now - lastAt).coerceAtLeast(1L)
            val downBps = ((rx - lastRx).coerceAtLeast(0L) * 1000L) / elapsed
            val upBps = ((tx - lastTx).coerceAtLeast(0L) * 1000L) / elapsed
            lastRx = rx
            lastTx = tx
            lastAt = now
            uploadSpeedSamples.add(upBps)
            downloadSpeedSamples.add(downBps)
            if (uploadSpeedSamples.size > 60) uploadSpeedSamples.removeAt(0)
            if (downloadSpeedSamples.size > 60) downloadSpeedSamples.removeAt(0)
        }
    }
    LaunchedEffect(state.vpnRequested, state.selectedNodeIndex) {
        if (!state.vpnRequested) {
            latencySamples.clear()
            return@LaunchedEffect
        }
        while (state.vpnRequested) {
            latencySamples.add(viewModel.probeVpnConnectivityNow())
            if (latencySamples.size > 60) latencySamples.removeAt(0)
            delay(1000)
        }
    }
    if (state.subscriptionBlocked) {
        val blockTitle = stringResource(
            id = when (state.subscriptionBlockReason) {
                SUBSCRIPTION_BLOCK_NO_PLAN -> R.string.subscription_no_plan_title
                SUBSCRIPTION_BLOCK_TRAFFIC -> R.string.subscription_traffic_exceeded_title
                else -> R.string.subscription_expired_title
            }
        )
        val blockDescription = stringResource(
            id = when (state.subscriptionBlockReason) {
                SUBSCRIPTION_BLOCK_NO_PLAN -> R.string.subscription_no_plan_body
                SUBSCRIPTION_BLOCK_TRAFFIC -> R.string.subscription_traffic_exceeded_body
                else -> R.string.subscription_expired_body
            }
        )
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
                .padding(bottom = 12.dp),
            cornerRadius = XbCardRadius,
            colors = xbImportantCardColors(),
            insideMargin = PaddingValues(18.dp)
        ) {
            Text(blockTitle, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(blockDescription, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            if (state.subscriptionSummary.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text(state.subscriptionSummary, style = MiuixTheme.textStyles.title2, fontFamily = FontFamily.Monospace)
            }
            Spacer(Modifier.height(14.dp))
            XbPrimaryButton(
                onClick = { viewModel.openScreen(PassScreen.PLANS) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.subscription_redeem_button))
            }
        }
        return
    }
    ConnectionStatusCard(state, now, onRoutingMode = viewModel::setRoutingMode) {
        if (state.vpnRequested) viewModel.stopVpn(context) else viewModel.requestStartVpn()
    }
    Spacer(Modifier.height(12.dp))
    if (state.vpnRequested) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
        ) {
            LatencyChart(samples = latencySamples, modifier = Modifier.weight(1f))
            SpeedChart(upload = uploadSpeedSamples, download = downloadSpeedSamples, modifier = Modifier.weight(1f))
        }
        Spacer(Modifier.height(12.dp))
    }
    val nodeTitle = selectedNode?.displayName(selectedIndex, stringResource(R.string.node_default_name, selectedIndex + 1))
        ?: stringResource(id = if (state.nodesLoading) R.string.status_nodes_syncing else R.string.status_no_nodes)
    val latencyText = if (selectedNode != null) visibleNodeTestText(state.nodeTestResults[selectedIndex]) else null
    val nodeSummary = listOfNotNull(selectedNode?.protocolLabel, latencyText?.let { stringResource(R.string.node_latency, it) }).joinToString(" · ")
    PreferenceCard {
        ArrowPreference(
            title = nodeTitle,
            summary = nodeSummary.ifBlank { stringResource(R.string.section_current_node) },
            onClick = { viewModel.openScreen(PassScreen.NODE_SELECT) }
        )
    }
    if (state.subscriptionSummary.isNotEmpty()) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
                .xbCardBorder(),
            cornerRadius = XbCardRadius,
            colors = xbCardColors(),
            insideMargin = PaddingValues(18.dp)
        ) {
            Text(stringResource(R.string.section_traffic), fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(4.dp))
            Text(
                state.subscriptionSummary,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                fontFamily = FontFamily.Monospace
            )
            if (state.subscriptionTrafficTotalBytes > 0L) {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = (state.subscriptionTrafficUsedBytes.toFloat() / state.subscriptionTrafficTotalBytes.toFloat()).coerceIn(0f, 1f),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            if (state.vpnRequested) {
                Spacer(Modifier.height(10.dp))
                Text(
                    "${stringResource(R.string.session_traffic)} · ${formatTrafficBytes((state.vpnSessionRxBytes + state.vpnSessionTxBytes).toDouble())}",
                    style = MiuixTheme.textStyles.body2,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    fontFamily = FontFamily.Monospace
                )
            }
        }
    }
}

@Composable
private fun ConnectionStatusCard(
    state: XbClientUiState,
    now: Long,
    onRoutingMode: (String) -> Unit,
    onToggle: () -> Unit
) {
    val connected = state.vpnRequested && !state.vpnStarting
    val statusText = stringResource(
        id = when {
            state.vpnStarting -> R.string.status_connecting
            state.vpnRequested -> R.string.status_connected
            else -> R.string.status_disconnected
        }
    )
    val actionText = stringResource(
        id = when {
            state.vpnStarting -> R.string.status_connecting
            state.vpnRequested -> R.string.action_disconnect
            else -> R.string.action_connect
        }
    )
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .animateContentSize(animationSpec = tween(180)),
        cornerRadius = XbCardRadius,
        colors = xbImportantCardColors(),
        insideMargin = PaddingValues(18.dp)
    ) {
        Text(
            statusText,
            fontSize = 22.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (connected) xbTokens().accent else xbTokens().textPrimary
        )
        if (state.vpnRequested) {
            Spacer(Modifier.height(6.dp))
            AnimatedContent(
                targetState = formatDuration((now - state.vpnConnectedAt).coerceAtLeast(0L)),
                transitionSpec = { contentTransition() },
                label = "connection-duration"
            ) { text ->
                Text(text, style = MiuixTheme.textStyles.title2, fontFamily = FontFamily.Monospace)
            }
        } else {
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.connection_idle_hint), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        }
        Spacer(Modifier.height(14.dp))
        RoutingModeSelector(
            selected = state.routingMode,
            enabled = !state.vpnStarting,
            onSelect = onRoutingMode
        )
        Spacer(Modifier.height(14.dp))
        Button(
            onClick = onToggle,
            enabled = !state.vpnStarting,
            modifier = Modifier
                .fillMaxWidth()
                .then(if (state.vpnRequested) Modifier.xbControlBorder() else Modifier),
            cornerRadius = XbControlRadius,
            colors = if (state.vpnRequested) xbSecondaryButtonColors() else xbPrimaryButtonColors()
        ) {
            AnimatedContent(targetState = actionText, transitionSpec = { contentTransition() }, label = "connection-action") { text ->
                Text(text)
            }
        }
    }
}

/**
 * 路由模式分段选择（规则/全局/直连）。
 * D 语言：描边药丸容器 + 选中项反白（暗色反白 / 亮色反黑），与 electron 端 .routing-toggle 同语义。
 */
@Composable
private fun RoutingModeSelector(selected: String, enabled: Boolean, onSelect: (String) -> Unit) {
    val t = xbTokens()
    val pill = RoundedCornerShape(50)
    val modes = listOf(
        ROUTING_MODE_RULE to stringResource(R.string.routing_mode_rule),
        ROUTING_MODE_GLOBAL to stringResource(R.string.routing_mode_global),
        ROUTING_MODE_DIRECT to stringResource(R.string.routing_mode_direct)
    )
    Row(
        modifier = Modifier
            .border(1.dp, t.controlBorder, pill)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        modes.forEach { (value, label) ->
            val active = value == selected
            Text(
                label,
                style = MiuixTheme.textStyles.body2,
                color = when {
                    active -> t.buttonPrimaryText
                    enabled -> t.textMuted
                    else -> t.textFaint
                },
                modifier = Modifier
                    .clip(pill)
                    .background(if (active) t.buttonPrimaryBg else Color.Transparent)
                    .clickable(enabled = enabled && !active) { onSelect(value) }
                    .padding(horizontal = 14.dp, vertical = 6.dp)
            )
        }
    }
}

@Composable
private fun LatencyChart(samples: List<Int>, modifier: Modifier = Modifier) {
    val gridColor = MiuixTheme.colorScheme.outline
    val lineColor = MiuixTheme.colorScheme.primary
    val current = samples.lastOrNull()
    val header = when {
        current == null -> "- ms"
        current < 0 -> "-"
        else -> "$current ms"
    }
    ChartCard(modifier = modifier, header = header, headerColor = lineColor) {
        val valid = samples.filter { it >= 0 }
        if (valid.size < 2) return@ChartCard
        val max = (valid.maxOrNull() ?: 100).coerceAtLeast(1)
        val min = (valid.minOrNull() ?: 0)
        val range = (max - min).coerceAtLeast(1)
        val path = Path()
        valid.forEachIndexed { index, value ->
            val x = (index.toFloat() / (valid.size - 1)) * size.width
            val y = size.height * (1f - ((value - min).toFloat() / range).coerceIn(0f, 1f))
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawGrid(gridColor)
        drawPath(path = path, color = lineColor, style = Stroke(width = 2.dp.toPx()))
    }
}

@Composable
private fun SpeedChart(upload: List<Long>, download: List<Long>, modifier: Modifier = Modifier) {
    val gridColor = MiuixTheme.colorScheme.outline
    val upColor = MiuixTheme.colorScheme.primary
    val downColor = xbTokens().textMuted
    val curUp = upload.lastOrNull() ?: 0L
    val curDown = download.lastOrNull() ?: 0L
    val header = "↑${formatTrafficBytes(curUp.toDouble())}/s ↓${formatTrafficBytes(curDown.toDouble())}/s"
    ChartCard(modifier = modifier, header = header, headerColor = MiuixTheme.colorScheme.onSurface) {
        val peak = ((upload + download).maxOrNull() ?: 0L).coerceAtLeast(1L)
        drawGrid(gridColor)
        drawSpeedLine(download, peak, downColor)
        drawSpeedLine(upload, peak, upColor)
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGrid(color: Color) {
    val gridLines = 4
    for (i in 0..gridLines) {
        val y = size.height * (i.toFloat() / gridLines)
        drawLine(color = color, start = Offset(0f, y), end = Offset(size.width, y), strokeWidth = 0.5.dp.toPx())
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawSpeedLine(values: List<Long>, peak: Long, color: Color) {
    if (values.size < 2) return
    val path = Path()
    values.forEachIndexed { index, value ->
        val x = (index.toFloat() / (values.size - 1)) * size.width
        val y = size.height * (1f - (value.toFloat() / peak).coerceIn(0f, 1f))
        if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
    }
    drawPath(path = path, color = color, style = Stroke(width = 2.dp.toPx()))
}

@Composable
private fun ChartCard(
    modifier: Modifier = Modifier,
    header: String,
    headerColor: Color,
    draw: androidx.compose.ui.graphics.drawscope.DrawScope.() -> Unit,
) {
    Card(
        modifier = modifier.xbCardBorder(),
        cornerRadius = XbCardRadius,
        colors = xbCardColors(),
        insideMargin = PaddingValues(12.dp)
    ) {
        Text(
            header,
            style = MiuixTheme.textStyles.body2,
            color = headerColor,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(8.dp))
        Canvas(modifier = Modifier.fillMaxWidth().height(72.dp)) { draw() }
    }
}

@Composable
internal fun NodeSelectScreen(state: XbClientUiState, viewModel: XbClientViewModel, modifier: Modifier = Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = 12.dp, bottom = 28.dp),
        overscrollEffect = null
    ) {
        item {
            if (!state.subscriptionBlocked && state.anyTlsNodes.isNotEmpty()) {
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.End) {
                    XbSecondaryButton(
                        onClick = viewModel::testAllNodes,
                        enabled = !state.nodesTesting
                    ) {
                        Text(stringResource(id = if (state.nodesTesting) R.string.action_test_testing else R.string.action_test_all_nodes))
                    }
                }
            }
            if (state.subscriptionBlocked) {
                val blockTitle = stringResource(
                    id = when (state.subscriptionBlockReason) {
                        SUBSCRIPTION_BLOCK_NO_PLAN -> R.string.subscription_no_plan_title
                        SUBSCRIPTION_BLOCK_TRAFFIC -> R.string.subscription_traffic_exceeded_title
                        else -> R.string.subscription_expired_title
                    }
                )
                val blockDescription = stringResource(
                    id = when (state.subscriptionBlockReason) {
                        SUBSCRIPTION_BLOCK_NO_PLAN -> R.string.subscription_no_plan_body
                        SUBSCRIPTION_BLOCK_TRAFFIC -> R.string.subscription_traffic_exceeded_body
                        else -> R.string.subscription_expired_body
                    }
                )
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp)
                        .padding(top = 12.dp),
                    cornerRadius = XbCardRadius,
                    colors = xbImportantCardColors(),
                    insideMargin = PaddingValues(18.dp)
                ) {
                    Text(blockTitle, style = MiuixTheme.textStyles.title2)
                    Spacer(Modifier.height(8.dp))
                    Text(blockDescription, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                    Spacer(Modifier.height(14.dp))
                    XbPrimaryButton(
                        onClick = { viewModel.openScreen(PassScreen.PLANS) },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(stringResource(R.string.subscription_redeem_button))
                    }
                }
            }
        }
        if (!state.subscriptionBlocked) {
            if (state.anyTlsNodes.isEmpty()) {
                item {
                    PreferenceCard(modifier = Modifier.padding(top = 12.dp)) {
                        Text(
                            stringResource(id = if (state.nodesLoading) R.string.status_nodes_syncing else R.string.status_no_nodes_sentence),
                            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            } else {
                itemsIndexed(state.anyTlsNodes, key = { index, node -> "${node.displayName(index)}-$index" }) { index, node ->
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp)
                            .padding(top = if (index == 0) 12.dp else 0.dp)
                            .padding(bottom = 8.dp)
                            .then(if (node.isInfo) Modifier.xbInfoFrame() else Modifier.xbCardBorder(listRow = true)),
                        cornerRadius = XbCardRadius,
                        colors = xbCardColors()
                    ) {
                        NodeRow(
                            index = index,
                            node = node,
                            selected = index == state.selectedNodeIndex,
                            testText = state.nodeTestResults[index],
                            onTest = { viewModel.testNode(index) },
                            onSelect = { viewModel.selectNode(index, returnToNodes = true) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NodeRow(
    index: Int,
    node: AnyTlsNode,
    selected: Boolean,
    testText: String?,
    onTest: () -> Unit,
    onSelect: () -> Unit
) {
    // 信息条目（订阅公告伪节点）：虚线边框 + 50% 透明（由外层卡片的 xbInfoFrame 承担），不可点击连接、无测速按钮
    if (node.isInfo) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp)
        ) {
            Text(node.name.trim().ifEmpty { node.displayName(index, stringResource(R.string.node_default_name, index + 1)) })
        }
        return
    }
    val tagsText = node.tags.joinToString(" · ").takeIf { it.isNotEmpty() }
    val visibleTestText = visibleNodeTestText(testText)
    val summary = listOfNotNull(node.protocolLabel, tagsText, visibleTestText).joinToString(" · ")
    RadioButtonPreference(
        title = node.displayName(index, stringResource(R.string.node_default_name, index + 1)),
        summary = summary,
        selected = selected,
        onClick = onSelect,
        endActions = {
            IconButton(onClick = onTest, modifier = Modifier.size(34.dp)) {
                Text("↻")
            }
        }
    )
}
