package moe.telecom.xbclient

import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch

class AuthActivity : ComponentActivity() {
    private val viewModel: XbClientViewModel by viewModels()
    private var redirectedToMain = false
    private var pendingOAuthUri: Uri? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.events.collect { event ->
                    when (event) {
                        is XbClientEvent.Message -> Toast.makeText(this@AuthActivity, event.text, Toast.LENGTH_SHORT).show()
                        is XbClientEvent.OpenExternalUrl -> BrowserOpener.open(this@AuthActivity, event.url)
                        else -> Unit
                    }
                }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { state ->
                    if (!state.loaded) {
                        return@collect
                    }
                    applyEdgeToEdge(state.themeMode)
                    pendingOAuthUri?.let { uri ->
                        pendingOAuthUri = null
                        dispatchOAuthUri(uri)
                        if (redirectedToMain) {
                            return@collect
                        }
                    }
                    if (state.isLoggedIn && state.languageOnboardingDone && state.vpnDisclosureDone && !redirectedToMain) {
                        redirectedToMain = true
                        startActivity(
                            Intent(this@AuthActivity, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        )
                        finish()
                    }
                }
            }
        }
        setContent {
            XbClientAuthApp(viewModel)
        }
        handleLaunchIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLaunchIntent(intent)
    }

    private fun handleLaunchIntent(intent: Intent?) {
        val uri = intent?.data
        if (uri?.scheme == BuildConfig.OAUTH_CALLBACK_SCHEME && uri.host == "oauth") {
            if (viewModel.uiState.value.loaded) {
                dispatchOAuthUri(uri)
            } else {
                pendingOAuthUri = uri
            }
        }
    }

    // 已登录时深链是绑定结果，必须交给 MainActivity 的 ViewModel 处理：
    // 绑定发起时的 pendingOAuthState、绑定列表和提示收集器都在那个实例里，
    // 本页的临时 ViewModel 处理会导致校验被跳过、绑定列表不刷新、提示丢失
    private fun dispatchOAuthUri(uri: Uri) {
        if (viewModel.uiState.value.isLoggedIn) {
            redirectedToMain = true
            startActivity(
                Intent(this@AuthActivity, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .setData(uri)
            )
            finish()
        } else {
            viewModel.handleOAuthCallback(uri)
        }
    }

    private fun applyEdgeToEdge(themeMode: String) {
        val darkTheme = when (themeMode) {
            "dark" -> true
            "light" -> false
            else -> (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        if (darkTheme) {
            enableEdgeToEdge(
                statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
                navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT)
            )
        } else {
            enableEdgeToEdge(
                statusBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
                navigationBarStyle = SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
            )
        }
    }
}
