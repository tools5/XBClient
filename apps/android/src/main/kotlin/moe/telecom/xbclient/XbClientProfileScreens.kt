package moe.telecom.xbclient

import android.content.ClipData
import android.content.ClipboardManager
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.util.Locale
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.HorizontalDivider
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextField
import top.yukonga.miuix.kmp.overlay.OverlayDialog
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.preference.OverlayDropdownPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme

@Composable
internal fun ProfileScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    val context = LocalContext.current
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(bottom = 12.dp)
            .xbCardBorder(),
        cornerRadius = XbCardRadius,
        colors = xbCardColors(),
        insideMargin = PaddingValues(18.dp)
    ) {
        Text(state.userEmail, style = MiuixTheme.textStyles.title2)
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(R.string.balance_amount, formatMoney(state.balance, state.currencySymbol, state.currencyUnit)),
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            fontFamily = FontFamily.Monospace
        )
        Spacer(Modifier.height(4.dp))
        Text(
            stringResource(R.string.commission_amount, formatMoney(state.commissionBalance, state.currencySymbol, state.currencyUnit)),
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            fontFamily = FontFamily.Monospace
        )
        Spacer(Modifier.height(8.dp))
        val subscriptionText = state.subscriptionSummary.ifEmpty {
            stringResource(id = if (state.subscribeUrl.isEmpty()) R.string.subscription_not_synced else R.string.subscription_synced)
        }
        Text(subscriptionText, color = MiuixTheme.colorScheme.onSurfaceVariantSummary, fontFamily = FontFamily.Monospace)
    }
    PreferenceCard {
        ArrowPreference(title = stringResource(R.string.page_account_security), onClick = { viewModel.openScreen(PassScreen.ACCOUNT_SECURITY) })
        ArrowPreference(title = stringResource(R.string.page_orders), onClick = { viewModel.openScreen(PassScreen.ORDERS) })
        ArrowPreference(title = stringResource(R.string.page_gift_cards), onClick = { viewModel.openScreen(PassScreen.GIFT_CARDS) })
        ArrowPreference(title = stringResource(R.string.common_logout), onClick = viewModel::logout)
    }
    RewardAdSection(
        title = stringResource(R.string.reward_points_title),
        enabled = state.pointsRewardAdEnabled,
        scene = REWARD_SCENE_POINTS,
        state = state,
        viewModel = viewModel
    )
    PreferenceCard {
        ArrowPreference(title = stringResource(R.string.page_traffic_logs), onClick = { viewModel.openScreen(PassScreen.TRAFFIC_LOGS) })
        ArrowPreference(title = stringResource(R.string.page_invite_details), onClick = { viewModel.openScreen(PassScreen.INVITE_DETAILS) })
        ArrowPreference(title = stringResource(R.string.page_tickets), onClick = { viewModel.openScreen(PassScreen.TICKETS) })
    }
    if (state.inviteForce || state.inviteCommissionRate > 0) {
        Section(stringResource(R.string.section_invite)) {
            Panel {
                Text(stringResource(R.string.invite_aff_rate, state.inviteCommissionRate), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(R.string.invite_commission_account, formatMoney(state.inviteCommissionBalance, state.currencySymbol, state.currencyUnit)),
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary
                )
                Spacer(Modifier.height(12.dp))
                if (state.invites.isEmpty()) {
                    Text(stringResource(id = if (state.invitesLoading) R.string.invite_loading else R.string.invite_empty), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                } else {
                    val copiedText = stringResource(R.string.invite_code_copied)
                    for ((index, invite) in state.invites.withIndex()) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.weight(1f)) {
                                Text(invite.code, style = MiuixTheme.textStyles.title2)
                                Text(stringResource(id = if (invite.status == 0) R.string.invite_available else R.string.invite_used), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                            }
                            XbTextButton(
                                text = stringResource(R.string.invite_copy),
                                onClick = {
                                    context.getSystemService(ClipboardManager::class.java)
                                        .setPrimaryClip(ClipData.newPlainText("invite", invite.code))
                                    Toast.makeText(context, copiedText, Toast.LENGTH_SHORT).show()
                                }
                            )
                        }
                        if (index != state.invites.lastIndex) {
                            HorizontalDivider(Modifier.padding(vertical = 10.dp))
                        }
                    }
                }
                Spacer(Modifier.height(14.dp))
                XbPrimaryButton(
                    onClick = viewModel::generateInvite,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(stringResource(R.string.action_generate_invite))
                }
            }
        }
    }
}

@Composable
internal fun OrdersScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    var cancelTradeNo by rememberSaveable { mutableStateOf("") }
    Section(stringResource(R.string.page_orders)) {
        when {
            state.ordersLoading && state.orders.isEmpty() -> Panel {
                Text(stringResource(R.string.orders_loading), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            }
            state.orders.isEmpty() -> Panel {
                Text(stringResource(R.string.orders_empty), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            }
            else -> {
                for ((index, order) in state.orders.withIndex()) {
                    OrderRow(
                        order = order,
                        state = state,
                        viewModel = viewModel,
                        onCancelRequest = { cancelTradeNo = it }
                    )
                    if (index != state.orders.lastIndex) {
                        Spacer(Modifier.height(12.dp))
                    }
                }
            }
        }
    }
    OverlayDialog(
        show = cancelTradeNo.isNotEmpty(),
        title = stringResource(R.string.order_cancel_confirm_title),
        summary = stringResource(R.string.order_cancel_confirm_message, cancelTradeNo),
        onDismissRequest = { cancelTradeNo = "" }
    ) {
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            XbTextButton(
                text = stringResource(android.R.string.cancel),
                onClick = { cancelTradeNo = "" },
                modifier = Modifier.weight(1f)
            )
            Spacer(Modifier.width(20.dp))
            XbTextButton(
                text = stringResource(R.string.order_cancel),
                onClick = {
                    viewModel.cancelOrder(cancelTradeNo)
                    cancelTradeNo = ""
                },
                modifier = Modifier.weight(1f),
                primary = true
            )
        }
    }
}

@Composable
private fun OrderRow(
    order: OrderItem,
    state: XbClientUiState,
    viewModel: XbClientViewModel,
    onCancelRequest: (String) -> Unit
) {
    val periodText = orderPeriodText(order.period)
    // plan 名可为空（充值订单 / 套餐已删除）：充值按 period 回退，其余显示 “-”
    val title = order.planName.ifBlank { if (order.period == ORDER_PERIOD_DEPOSIT) periodText else "-" }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .xbCardBorder(),
        cornerRadius = XbCardRadius,
        colors = xbCardColors(),
        insideMargin = PaddingValues(16.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MiuixTheme.textStyles.title2)
                if (periodText != title) {
                    Spacer(Modifier.height(2.dp))
                    Text(periodText, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                }
            }
            Spacer(Modifier.width(12.dp))
            OrderStatusTag(order.status)
        }
        Spacer(Modifier.height(8.dp))
        Text(
            formatMoney(order.payableAmount, state.currencySymbol, state.currencyUnit),
            fontFamily = FontFamily.Monospace
        )
        if (order.balanceAmount > 0) {
            Spacer(Modifier.height(2.dp))
            Text(
                stringResource(R.string.order_balance_deduct, formatMoney(order.balanceAmount, state.currencySymbol, state.currencyUnit)),
                style = MiuixTheme.textStyles.body2,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                fontFamily = FontFamily.Monospace
            )
        }
        val meta = listOf(order.tradeNo, formatUnixTime(order.createdAt)).filter { it.isNotEmpty() }.joinToString(" · ")
        if (meta.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Text(meta, style = MiuixTheme.textStyles.body2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        }
        if (order.status == ORDER_STATUS_PENDING) {
            Spacer(Modifier.height(12.dp))
            if (order.paymentId != null) {
                // xiao 面板对已绑定支付方式（payment_id 非空）的订单会拒绝取消，隐藏取消入口
                Text(
                    stringResource(R.string.order_external_payment_hint),
                    style = MiuixTheme.textStyles.body2,
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary
                )
                Spacer(Modifier.height(8.dp))
                XbPrimaryButton(
                    onClick = { viewModel.continuePayOrder(order.tradeNo) },
                    enabled = !state.paymentLoading,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(stringResource(R.string.order_pay_continue))
                }
            } else {
                Row(modifier = Modifier.fillMaxWidth()) {
                    XbPrimaryButton(
                        onClick = { viewModel.continuePayOrder(order.tradeNo) },
                        enabled = !state.paymentLoading,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(stringResource(R.string.order_pay_continue))
                    }
                    Spacer(Modifier.width(10.dp))
                    XbSecondaryButton(
                        onClick = { onCancelRequest(order.tradeNo) },
                        enabled = !state.paymentLoading,
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(stringResource(R.string.order_cancel))
                    }
                }
            }
        }
    }
}

/**
 * 订单状态徽标（克制配色）：待支付=描边黄 / 开通中=描边灰 / 已完成=绿 tag 色块 /
 * 已取消=弱化描边 / 已折抵及未知=描边灰。
 */
@Composable
private fun OrderStatusTag(status: Int) {
    val t = xbTokens()
    val filled = status == ORDER_STATUS_COMPLETED
    val statusColor = when (status) {
        ORDER_STATUS_PENDING -> t.warning
        ORDER_STATUS_COMPLETED -> t.tagText
        ORDER_STATUS_CANCELLED -> t.textFaint
        else -> t.textMuted
    }
    Card(
        colors = CardDefaults.defaultColors(color = if (filled) t.tagBg else Color.Transparent),
        cornerRadius = XbControlRadius,
        modifier = if (filled) Modifier else Modifier.xbOutlineTagBorder(statusColor),
        insideMargin = PaddingValues(horizontal = 10.dp, vertical = 6.dp)
    ) {
        Text(orderStatusText(status), style = MiuixTheme.textStyles.body2, color = statusColor)
    }
}

@Composable
private fun orderStatusText(status: Int): String =
    when (status) {
        ORDER_STATUS_PENDING -> stringResource(R.string.order_status_pending)
        ORDER_STATUS_PROCESSING -> stringResource(R.string.order_status_processing)
        ORDER_STATUS_CANCELLED -> stringResource(R.string.order_status_cancelled)
        ORDER_STATUS_COMPLETED -> stringResource(R.string.order_status_completed)
        ORDER_STATUS_DISCOUNTED -> stringResource(R.string.order_status_discounted)
        else -> stringResource(R.string.order_status_unknown, status)
    }

private val ORDER_PERIOD_PRICE_FIELDS = setOf(
    "month_price", "quarter_price", "half_year_price", "year_price",
    "two_year_price", "three_year_price", "onetime_price", "reset_price"
)

@Composable
private fun orderPeriodText(period: String): String =
    when {
        period == ORDER_PERIOD_DEPOSIT -> stringResource(R.string.order_period_deposit)
        period in ORDER_PERIOD_PRICE_FIELDS -> planPriceLabel(period)
        // Xboard 新版可能用重命名后的周期字段，未知值原样展示
        else -> period.ifBlank { "-" }
    }

@Composable
internal fun InviteDetailsScreen(state: XbClientUiState) {
    Section(stringResource(R.string.page_invite_details)) {
        Panel {
            Text(stringResource(R.string.invite_details_count, state.commissionTotal), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            Spacer(Modifier.height(12.dp))
            when {
                state.commissionLogsLoading -> Text(stringResource(R.string.invite_details_loading), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                state.commissionLogs.isEmpty() -> Text(stringResource(R.string.invite_details_empty), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                else -> {
                    for ((index, log) in state.commissionLogs.withIndex()) {
                        Text(stringResource(R.string.invite_details_order, log.tradeNo), style = MiuixTheme.textStyles.title2)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            stringResource(
                                R.string.invite_details_amounts,
                                formatMoney(log.orderAmount, state.currencySymbol, state.currencyUnit),
                                formatMoney(log.getAmount, state.currencySymbol, state.currencyUnit)
                            ),
                            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                            fontFamily = FontFamily.Monospace
                        )
                        val time = formatUnixTime(log.createdAt)
                        if (time.isNotEmpty()) {
                            Spacer(Modifier.height(2.dp))
                            Text(time, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                        }
                        if (index != state.commissionLogs.lastIndex) {
                            HorizontalDivider(Modifier.padding(vertical = 12.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun TrafficLogsScreen(state: XbClientUiState) {
    Section(stringResource(R.string.page_traffic_logs)) {
        Panel {
            when {
                state.trafficLogsLoading -> Text(stringResource(R.string.traffic_logs_loading), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                state.trafficLogs.isEmpty() -> Text(stringResource(R.string.traffic_logs_empty), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                else -> {
                    for ((index, log) in state.trafficLogs.withIndex()) {
                        val total = log.upload + log.download
                        Text(formatUnixTime(log.recordAt), style = MiuixTheme.textStyles.title2)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            stringResource(
                                R.string.traffic_logs_up_down,
                                formatTrafficBytes(log.upload.toDouble()),
                                formatTrafficBytes(log.download.toDouble())
                            ),
                            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                            fontFamily = FontFamily.Monospace
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            stringResource(
                                R.string.traffic_logs_total_rate,
                                formatTrafficBytes(total.toDouble()),
                                String.format(Locale.US, "%.2f", log.serverRate)
                            ),
                            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                            fontFamily = FontFamily.Monospace
                        )
                        if (index != state.trafficLogs.lastIndex) {
                            HorizontalDivider(Modifier.padding(vertical = 12.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun TicketsScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    var subject by rememberSaveable { mutableStateOf("") }
    var message by rememberSaveable { mutableStateOf("") }
    var level by rememberSaveable { mutableStateOf(0) }
    val levels = listOf(0, 1, 2)
    Section(stringResource(R.string.section_new_ticket)) {
        Panel {
            TextField(
                value = subject,
                onValueChange = { subject = it },
                label = stringResource(R.string.ticket_subject),
                useLabelAsPlaceholder = true,
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(10.dp))
            OverlayDropdownPreference(
                title = stringResource(R.string.ticket_level),
                items = levels.map { ticketLevelText(it) },
                selectedIndex = level,
                onSelectedIndexChange = { level = it }
            )
            Spacer(Modifier.height(10.dp))
            TextField(
                value = message,
                onValueChange = { message = it },
                label = stringResource(R.string.ticket_message),
                useLabelAsPlaceholder = true,
                minLines = 4,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(12.dp))
            XbPrimaryButton(
                onClick = { viewModel.createTicket(subject, level, message) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.ticket_submit))
            }
        }
    }
    Section(stringResource(R.string.section_my_tickets)) {
        Card(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp).xbCardBorder(),
            cornerRadius = XbCardRadius,
            colors = xbCardColors()
        ) {
            when {
                state.ticketsLoading -> Text(stringResource(R.string.ticket_loading), color = MiuixTheme.colorScheme.onSurfaceVariantSummary, modifier = Modifier.padding(16.dp))
                state.tickets.isEmpty() -> Text(stringResource(R.string.ticket_empty), color = MiuixTheme.colorScheme.onSurfaceVariantSummary, modifier = Modifier.padding(16.dp))
                else -> {
                    for (ticket in state.tickets) {
                        ArrowPreference(
                            title = ticket.subject,
                            summary = "${ticketStatusText(ticket.status)} · ${ticketReplyStatusText(ticket.replyStatus)} · ${ticketLevelText(ticket.level)} · ${formatUnixTime(ticket.updatedAt)}",
                            onClick = { viewModel.openTicket(ticket.id) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun TicketDetailScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    val ticket = state.selectedTicket
    var reply by rememberSaveable(ticket?.id) { mutableStateOf("") }
    Section(stringResource(R.string.page_ticket_detail)) {
        Panel {
            if (ticket == null) {
                Text(
                    stringResource(id = if (state.ticketDetailLoading) R.string.ticket_loading else R.string.ticket_not_selected),
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary
                )
            } else {
                Text(ticket.subject, style = MiuixTheme.textStyles.title2)
                Spacer(Modifier.height(6.dp))
                Text(
                    "${ticketStatusText(ticket.status)} · ${ticketReplyStatusText(ticket.replyStatus)} · ${ticketLevelText(ticket.level)}",
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary
                )
                val time = formatUnixTime(ticket.updatedAt)
                if (time.isNotEmpty()) {
                    Spacer(Modifier.height(2.dp))
                    Text(time, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                }
            }
        }
    }
    Section(stringResource(R.string.section_ticket_messages)) {
        Panel {
            when {
                state.ticketDetailLoading -> Text(stringResource(R.string.ticket_messages_loading), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                state.ticketMessages.isEmpty() -> Text(stringResource(R.string.ticket_messages_empty), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                else -> {
                    for (message in state.ticketMessages) {
                        Row(
                            horizontalArrangement = if (message.isMe) Arrangement.End else Arrangement.Start,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Card(
                                colors = if (message.isMe) {
                                    CardDefaults.defaultColors(color = MiuixTheme.colorScheme.primaryContainer)
                                } else {
                                    xbCardColors()
                                },
                                cornerRadius = XbCardRadius,
                                insideMargin = PaddingValues(14.dp),
                                modifier = Modifier
                                    .fillMaxWidth(0.86f)
                                    .then(if (message.isMe) Modifier else Modifier.xbCardBorder())
                            ) {
                                Text(message.message)
                                val time = formatUnixTime(message.createdAt)
                                if (time.isNotEmpty()) {
                                    Spacer(Modifier.height(6.dp))
                                    Text(time, style = MiuixTheme.textStyles.body2, color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                                }
                            }
                        }
                        Spacer(Modifier.height(10.dp))
                    }
                }
            }
        }
    }
    if (ticket != null && ticket.status == 0) {
        Section(stringResource(R.string.section_ticket_reply)) {
            Panel {
                TextField(
                    value = reply,
                    onValueChange = { reply = it },
                    label = stringResource(R.string.ticket_reply_hint),
                    useLabelAsPlaceholder = true,
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(Modifier.height(12.dp))
                XbPrimaryButton(
                    onClick = { viewModel.replyTicket(reply) },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(stringResource(R.string.ticket_reply_submit))
                }
                Spacer(Modifier.height(8.dp))
                XbSecondaryButton(onClick = viewModel::closeTicket, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.ticket_close))
                }
            }
        }
    }
}

@Composable
fun GiftCardsScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    var code by rememberSaveable { mutableStateOf("") }
    Section(stringResource(R.string.page_gift_cards)) {
        Panel {
            TextField(
                value = code,
                onValueChange = { code = it },
                label = stringResource(R.string.gift_code),
                useLabelAsPlaceholder = true,
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(12.dp))
            XbPrimaryButton(
                onClick = { viewModel.redeemGiftCard(code) },
                enabled = code.isNotBlank() && !state.giftCardRedeeming,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(id = if (state.giftCardRedeeming) R.string.gift_redeeming else R.string.gift_redeem))
            }
        }
    }
}

@Composable
fun AccountSecurityScreen(state: XbClientUiState, viewModel: XbClientViewModel) {
    var oldPassword by rememberSaveable { mutableStateOf("") }
    var newPassword by rememberSaveable { mutableStateOf("") }
    var confirmPassword by rememberSaveable { mutableStateOf("") }
    Section(stringResource(R.string.section_change_password)) {
        Panel {
            TextField(
                value = oldPassword,
                onValueChange = { oldPassword = it },
                label = stringResource(R.string.password_old),
                useLabelAsPlaceholder = true,
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(10.dp))
            TextField(
                value = newPassword,
                onValueChange = { newPassword = it },
                label = stringResource(R.string.password_new),
                useLabelAsPlaceholder = true,
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(10.dp))
            TextField(
                value = confirmPassword,
                onValueChange = { confirmPassword = it },
                label = stringResource(R.string.password_confirm),
                useLabelAsPlaceholder = true,
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(12.dp))
            XbPrimaryButton(
                onClick = { viewModel.changePassword(oldPassword, newPassword, confirmPassword) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.password_save))
            }
        }
    }
    if (state.oauthProviders.isNotEmpty()) {
        Section(stringResource(R.string.section_oauth_bindings)) {
            Panel {
                if (state.oauthBindingsLoading) {
                    Text(stringResource(R.string.oauth_bindings_loading), color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
                } else {
                    for ((index, provider) in state.oauthProviders.withIndex()) {
                        val binding = state.oauthBindings.firstOrNull { it.driver == provider.driver }
                        val bound = binding?.bound == true
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.weight(1f)) {
                                Text(provider.label, style = MiuixTheme.textStyles.title2)
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    if (bound) binding?.identity?.ifEmpty { stringResource(R.string.oauth_bound) } ?: stringResource(R.string.oauth_bound) else stringResource(R.string.oauth_unbound),
                                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary
                                )
                            }
                            if (bound) {
                                XbSecondaryButton(onClick = { viewModel.unbindOAuth(provider.driver) }) {
                                    Text(stringResource(R.string.oauth_unbind))
                                }
                            } else {
                                XbPrimaryButton(onClick = { viewModel.bindOAuth(provider.driver) }) {
                                    Text(stringResource(R.string.oauth_bind))
                                }
                            }
                        }
                        if (index != state.oauthProviders.lastIndex) {
                            HorizontalDivider(Modifier.padding(vertical = 10.dp))
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    XbSecondaryButton(
                        onClick = { viewModel.refreshOAuthBindings(force = true, showLoading = true, showErrors = true) },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(stringResource(R.string.oauth_refresh_bindings))
                    }
                }
            }
        }
    }
}
