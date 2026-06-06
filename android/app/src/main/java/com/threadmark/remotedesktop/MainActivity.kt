package com.threadmark.remotedesktop

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.util.Log
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.inputmethod.InputMethodManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.CookieManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Space
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.ByteArrayInputStream
import kotlin.math.abs

class MainActivity : Activity(), CoroutineScope by MainScope() {
    private lateinit var tokenStore: TokenStore
    private lateinit var cloudKit: CloudKitClient
    private var discovery: LocalHostDiscovery? = null
    private var transport: WebRtcTransport? = null
    private var remoteSurface: RemoteScreenSurface? = null
    private var hosts: List<LocalHostAdvertisement> = emptyList()
    private var pairingError: String? = null
    private var hostName: String? = null
    private var displayInfo: DisplayInfo? = null
    private var softModifierMask = 0
    private var statusHostText: TextView? = null
    private var statusModeText: TextView? = null
    private var modifierButtons: Map<SoftModifier, Button> = emptyMap()
    private var showCodeEntry = false
    private var lastScreen: Screen = Screen.Auth
    private var codeEntry: EditText? = null

    // In-session chrome (retractable status bar + idle-translucent input dock)
    private val uiHandler = Handler(Looper.getMainLooper())
    private var statusStripView: View? = null
    private var dragHandleView: View? = null
    private var inputDockView: View? = null
    private var chromeRevealed = false
    private var dockIdle = false
    private val hideChromeRunnable = Runnable { applyChromeRevealed(false, animate = true) }
    private val dockIdleRunnable = Runnable {
        if (softModifierMask == 0 && !softKeyboardHasFocus()) applyDockIdle(true)
    }

    // Video is attached only once the surface is laid out at the correct
    // aspect, so the first frame renders fitted (not zoomed) with no later
    // blanking resize — important for hosts that only send frames on change.
    private var videoAttached = false
    private val videoAttachFallback = Runnable { attachVideoIfReady() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        tokenStore = TokenStore(this)
        cloudKit = CloudKitClient(tokenStore)
        renderCheckingLogin()
        validateLogin()
    }

    override fun onDestroy() {
        super.onDestroy()
        discovery?.stop()
        detachRemoteSurface()
        transport?.dispose()
        cancel()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (lastScreen == Screen.Session && event.action in setOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            val usage = HidKeyMapper.usageForKeyCode(event.keyCode)
            if (usage != null) {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount > 0) return true
                transport?.send(
                    ControlMessage.Key(
                        usage = usage,
                        down = event.action == KeyEvent.ACTION_DOWN,
                        modifiers = HidKeyMapper.modifierMask(event, softModifierMask),
                    )
                )
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun validateLogin() {
        if (!Config.hasCloudKitApiToken) {
            renderAuth(
                "CloudKit API token is missing. Build with REMOTE_DESKTOP_CLOUDKIT_API_TOKEN before signing in.",
                checking = false,
            )
            return
        }
        if (tokenStore.webAuthToken.isNullOrBlank()) {
            renderAuth(checking = false)
            return
        }
        launch {
            renderAuth(checking = true)
            try {
                cloudKit.currentUser()
                renderPairing()
            } catch (error: Throwable) {
                tokenStore.clearLogin()
                renderAuth(error.message ?: "Apple ID sign-in expired.", checking = false)
            }
        }
    }

    private fun startLogin() {
        launch {
            renderAuth(checking = true)
            try {
                val redirectUrl = cloudKit.authenticationRedirectUrl()
                renderWebLogin(redirectUrl)
            } catch (error: Throwable) {
                renderAuth(error.message ?: "Couldn't start Apple ID sign-in.", checking = false)
            }
        }
    }

    private fun renderCheckingLogin() {
        lastScreen = Screen.Auth
        showSystemChrome()
        stopDiscovery()
        detachRemoteSurface()
        val root = centeredRoot()
        root.addView(ProgressBar(this))
        root.addView(label("Checking sign-in", 17f, Color.rgb(25, 31, 42), bold = true))
        setContentView(root)
    }

    private fun renderAuth(error: String? = null, checking: Boolean = false) {
        lastScreen = Screen.Auth
        showSystemChrome()
        stopDiscovery()
        detachRemoteSurface()
        val root = ScrollView(this).apply {
            setBackgroundColor(Color.rgb(243, 245, 247))
            isFillViewport = true
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(54), dp(28), dp(32))
        }
        root.addView(content, ViewGroup.LayoutParams(match, wrap))
        content.addView(LogoView(this), LinearLayout.LayoutParams(dp(82), dp(82)))
        content.addView(label("RemoteDesktop", 31f, Color.rgb(12, 18, 31), bold = true).withTop(22))
        content.addView(
            label(
                "Sign in with the same Apple ID used on your host, then choose a nearby device or enter its pairing code.",
                16f,
                Color.rgb(91, 101, 117),
                gravity = Gravity.CENTER,
            ).withTop(10).withMaxWidth(dp(520))
        )
        if (error != null) {
            content.addView(errorBanner(error).withTop(22).withMaxWidth(dp(560)))
        }
        val button = primaryButton(if (checking) "Checking..." else "Sign in with Apple ID") {
            startLogin()
        }.apply {
            isEnabled = !checking && Config.hasCloudKitApiToken
        }
        content.addView(button.withTop(26).withMaxWidth(dp(360)))
        setContentView(root)
    }

    private fun renderWebLogin(url: String) {
        lastScreen = Screen.Auth
        showSystemChrome()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        val top = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(10), dp(10), dp(10))
            background = solid(Color.rgb(248, 250, 252))
        }
        top.addView(label("Apple ID sign-in", 18f, Color.rgb(15, 23, 42), bold = true), LinearLayout.LayoutParams(0, wrap, 1f))
        top.addView(plainButton("Cancel") { renderAuth() })
        root.addView(top, LinearLayout.LayoutParams(match, dp(58)))

        val webView = WebView(this)
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.settings.javaScriptCanOpenWindowsAutomatically = true
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean = true
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                handleAuthRedirect(request.url)

            @Suppress("OVERRIDE_DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
                handleAuthRedirect(Uri.parse(url))

            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                if (handleAuthRedirect(Uri.parse(url))) {
                    view.stopLoading()
                    return
                }
                super.onPageStarted(view, url, favicon)
            }

            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                if (isAuthCallback(request.url)) {
                    runOnUiThread { handleAuthRedirect(request.url) }
                    return WebResourceResponse(
                        "text/plain",
                        "utf-8",
                        ByteArrayInputStream(ByteArray(0)),
                    )
                }
                return super.shouldInterceptRequest(view, request)
            }
        }
        root.addView(webView, LinearLayout.LayoutParams(match, 0, 1f))
        setContentView(root)
        webView.loadUrl(url)
    }

    private fun handleAuthRedirect(uri: Uri): Boolean {
        val token = webAuthTokenFrom(uri)
        if (token != null && (isAuthCallback(uri) || uri.host == "idmsa.apple.com")) {
            Log.i(TAG, "Captured CloudKit web auth token from Apple sign-in redirect host=${uri.host}")
            tokenStore.webAuthToken = token
            validateLogin()
            return true
        }

        return if (isAuthCallback(uri)) {
            Log.w(TAG, "Apple sign-in reached callback without ckWebAuthToken host=${uri.host}")
            renderAuth("Apple sign-in returned without a CloudKit token.", checking = false)
            true
        } else {
            false
        }
    }

    private fun isAuthCallback(uri: Uri): Boolean {
        val expected = Uri.parse(Config.cloudKitAuthCallbackUrl)
        return uri.scheme == expected.scheme &&
            uri.host == expected.host &&
            uri.path == expected.path
    }

    private fun webAuthTokenFrom(uri: Uri): String? {
        val token = uri.getQueryParameter("ckWebAuthToken")
            ?: uri.getQueryParameter("webAuthToken")
            ?: Uri.parse("x://callback?${uri.fragment.orEmpty()}").getQueryParameter("ckWebAuthToken")
            ?: Uri.parse("x://callback?${uri.fragment.orEmpty()}").getQueryParameter("webAuthToken")
        return token?.takeIf { it.isNotBlank() }
    }

    private fun renderPairing() {
        lastScreen = Screen.Pairing
        showSystemChrome()
        detachRemoteSurface()
        transport?.dispose()
        transport = null
        hostName = null
        displayInfo = null
        softModifierMask = 0
        startDiscovery()

        val scrollView = ScrollView(this).apply {
            isFillViewport = true
            background = verticalGradient(Color.rgb(242, 245, 249), Color.rgb(232, 237, 244))
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(38), dp(24), dp(36))
            gravity = Gravity.CENTER_HORIZONTAL
        }
        scrollView.addView(content, ViewGroup.LayoutParams(match, wrap))

        val header = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            orientation = LinearLayout.HORIZONTAL
        }
        header.addView(LogoView(this), LinearLayout.LayoutParams(dp(74), dp(74)))
        val headerText = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, 0, 0)
        }
        headerText.addView(label("Connect to host", 30f, Color.rgb(12, 18, 31), bold = true))
        headerText.addView(
            label(
                "Choose an available device first. If your host is not listed, enter its pairing code.",
                15f,
                Color.rgb(91, 101, 117),
            ).withTop(6)
        )
        header.addView(headerText, LinearLayout.LayoutParams(0, wrap, 1f))
        content.addView(header.withMaxWidth(dp(680)))

        pairingError?.let {
            content.addView(errorBanner(it).withTop(20).withMaxWidth(dp(680)))
        }

        content.addView(availableDevicesCard().withTop(22).withMaxWidth(dp(680)))
        content.addView(pairingCodeCard().withTop(16).withMaxWidth(dp(680)))

        setContentView(scrollView)
    }

    private var devicesCardView: LinearLayout? = null

    private fun availableDevicesCard(): View {
        val card = cardContainer()
        devicesCardView = card
        populateDevicesCard(card)
        return card
    }

    /// Refreshes just the device list in place (used when discovery updates
    /// arrive while the user is typing a pairing code, so focus is preserved).
    private fun refreshDeviceList() {
        devicesCardView?.let { populateDevicesCard(it) }
    }

    private fun populateDevicesCard(card: LinearLayout) {
        card.removeAllViews()
        card.addView(sectionHeader("Available devices", if (hosts.isEmpty()) null else hosts.size))
        if (hosts.isEmpty()) {
            val empty = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(16), dp(14), dp(16), dp(14))
                background = rounded(Color.rgb(245, 247, 250), dp(16))
            }
            empty.addView(ProgressBar(this), LinearLayout.LayoutParams(dp(34), dp(34)))
            val texts = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(14), 0, 0, 0)
            }
            texts.addView(label("Searching for hosts", 15f, Color.rgb(24, 31, 44), bold = true))
            texts.addView(label("Open the host app, or use a pairing code below.", 13f, Color.rgb(100, 110, 126)))
            empty.addView(texts, LinearLayout.LayoutParams(0, wrap, 1f))
            card.addView(empty.withTop(14))
        } else {
            hosts.forEach { host ->
                card.addView(hostButton(host).withTop(10))
            }
        }
    }

    private fun pairingCodeCard(): View {
        val card = cardContainer()
        card.addView(sectionHeader("Pair with code", null))
        val toggle = rowButton("Enter code", if (showCodeEntry) "⌃" else "⌄") {
            showCodeEntry = !showCodeEntry
            renderPairing()
        }
        card.addView(toggle.withTop(12))
        if (showCodeEntry) {
            val entryBox = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(16), dp(16), dp(16))
                background = rounded(Color.rgb(251, 252, 254), dp(18), Color.argb(16, 15, 23, 42), 1)
            }
            val edit = EditText(this).apply {
                hint = "000000"
                gravity = Gravity.CENTER
                textSize = 38f
                typeface = Typeface.MONOSPACE
                inputType = InputType.TYPE_CLASS_NUMBER
                filters = arrayOf(InputFilter.LengthFilter(6))
                background = rounded(Color.WHITE, dp(14), Color.argb(26, 15, 23, 42), 1)
                setPadding(dp(16), dp(12), dp(16), dp(12))
                addTextChangedListener(object : TextWatcher {
                    private var editing = false
                    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                    override fun afterTextChanged(s: Editable) {
                        if (editing) return
                        val filtered = s.filter(Char::isDigit).take(6).toString()
                        if (filtered != s.toString()) {
                            editing = true
                            setText(filtered)
                            setSelection(filtered.length)
                            editing = false
                        }
                        if (filtered.length == 6) connect(filtered)
                    }
                })
            }
            codeEntry = edit
            entryBox.addView(edit, LinearLayout.LayoutParams(match, wrap))
            entryBox.addView(primaryButton("Connect") {
                val code = edit.text.toString()
                if (code.length == 6) connect(code)
            }.withTop(14))
            card.addView(entryBox.withTop(12))
            // Focus the field and raise the keyboard so the user can type
            // immediately after expanding "Enter code".
            edit.post {
                edit.requestFocus()
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                    .showSoftInput(edit, InputMethodManager.SHOW_IMPLICIT)
            }
        } else {
            codeEntry = null
        }
        return card
    }

    private fun hostButton(host: LocalHostAdvertisement): View =
        rowButton(
            title = host.hostname,
            accessory = "›",
            subtitle = if (host.source == LocalHostAdvertisement.Source.CloudKit) "Ready through iCloud" else "Ready nearby",
        ) {
            connect(host.code)
        }

    private fun connect(code: String) {
        stopDiscovery()
        pairingError = null
        hostName = null
        displayInfo = null
        softModifierMask = 0
        val nextTransport = WebRtcTransport(
            context = this,
            cloudKit = cloudKit,
            tokenStore = tokenStore,
            scope = this,
            onHostHello = {
                hostName = it.hostname
                updateSessionStatus()
            },
            onDisplay = {
                displayInfo = it
                remoteSurface?.displayInfo = it
            },
            onDisconnect = { reason ->
                renderEnded(reason)
            },
        )
        transport = nextTransport
        renderSession(connecting = true)
        launch {
            try {
                nextTransport.connect(code)
            } catch (error: Throwable) {
                nextTransport.dispose()
                if (transport === nextTransport) transport = null
                pairingError = error.message ?: "Couldn't connect."
                renderPairing()
            }
        }
    }

    private fun renderSession(connecting: Boolean = false) {
        lastScreen = Screen.Session
        hideSystemChrome()
        detachRemoteSurface()

        val transport = transport
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        val surface = RemoteScreenSurface(this)
        remoteSurface = surface
        surface.displayInfo = displayInfo
        surface.onPointer = { x, y, buttons ->
            transport?.send(ControlMessage.Pointer(x, y, buttons))
        }
        surface.onScroll = { x, y, dx, dy, phase ->
            transport?.send(ControlMessage.Scroll(x, y, dx, dy, phase))
        }
        if (transport != null) {
            surface.initRenderer(transport.eglContext)
            surface.onVideoReady = { attachVideoIfReady() }
            // Attach anyway if the host never sends a display message, so video
            // is never blocked waiting on it.
            uiHandler.postDelayed(videoAttachFallback, 1500L)
        }
        root.addView(surface, FrameLayout.LayoutParams(match, match))

        root.addView(leftEdgeSwipeStrip(), FrameLayout.LayoutParams(dp(24), match, Gravity.START))

        val strip = statusStrip(connecting)
        statusStripView = strip
        val handle = topDragHandle()
        dragHandleView = handle
        val dock = inputDock()
        inputDockView = dock

        root.addView(strip, FrameLayout.LayoutParams(match, dp(62), Gravity.TOP))
        root.addView(handle, FrameLayout.LayoutParams(match, dp(46), Gravity.TOP))
        root.addView(dock, FrameLayout.LayoutParams(match, wrap, Gravity.BOTTOM))
        root.addView(softKeyboardCapture(), FrameLayout.LayoutParams(dp(1), dp(1), Gravity.BOTTOM or Gravity.END))
        setContentView(root)

        // Retract the status bar like iOS; the user pulls it down to reveal it.
        applyChromeRevealed(false, animate = false)
        dockIdle = false
        inputDockView?.alpha = 1f
        scheduleDockIdle()
    }

    // MARK: - Swipe-to-disconnect (left edge → right, like iOS)

    private fun leftEdgeSwipeStrip(): View {
        val strip = View(this)
        var startX = 0f
        var startY = 0f
        var triggered = false
        val threshold = dp(140).toFloat()
        strip.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = event.rawX
                    startY = event.rawY
                    triggered = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - startX
                    val dy = event.rawY - startY
                    if (!triggered && dx > threshold && abs(dy) < dx * 0.6f) {
                        triggered = true
                        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (triggered) transport?.disconnect()
                    true
                }
                else -> true
            }
        }
        return strip
    }

    // MARK: - Retractable chrome

    private fun topDragHandle(): View {
        val container = FrameLayout(this)
        val pill = View(this).apply {
            background = rounded(Color.argb(64, 255, 255, 255), dp(2))
        }
        container.addView(
            pill,
            FrameLayout.LayoutParams(dp(38), dp(4), Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM).apply {
                bottomMargin = dp(7)
            },
        )
        container.setOnTouchListener { _, event ->
            if (chromeRevealed) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> true
                MotionEvent.ACTION_UP -> {
                    applyChromeRevealed(true, animate = true)
                    true
                }
                else -> true
            }
        }
        return container
    }

    private fun applyChromeRevealed(revealed: Boolean, animate: Boolean) {
        chromeRevealed = revealed
        uiHandler.removeCallbacks(hideChromeRunnable)
        val strip = statusStripView ?: return
        val handle = dragHandleView
        val hiddenY = -dp(72).toFloat()
        if (animate) {
            strip.animate().translationY(if (revealed) 0f else hiddenY)
                .alpha(if (revealed) 1f else 0f).setDuration(220).start()
            handle?.animate()?.alpha(if (revealed) 0f else 1f)?.setDuration(220)?.start()
        } else {
            strip.translationY = if (revealed) 0f else hiddenY
            strip.alpha = if (revealed) 1f else 0f
            handle?.alpha = if (revealed) 0f else 1f
        }
        if (revealed) uiHandler.postDelayed(hideChromeRunnable, 3000L)
    }

    // MARK: - Idle-translucent input dock

    private fun softKeyboardHasFocus(): Boolean =
        findViewById<EditText?>(SOFT_KEYBOARD_CAPTURE_ID)?.hasFocus() == true

    private fun applyDockIdle(idle: Boolean) {
        dockIdle = idle
        inputDockView?.animate()?.alpha(if (idle) 0.5f else 1f)?.setDuration(300)?.start()
    }

    private fun scheduleDockIdle() {
        uiHandler.removeCallbacks(dockIdleRunnable)
        uiHandler.postDelayed(dockIdleRunnable, 3000L)
    }

    private fun wakeDock() {
        if (dockIdle) applyDockIdle(false)
        scheduleDockIdle()
    }

    private fun statusStrip(connecting: Boolean): View {
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(8), dp(12), dp(8))
            background = GradientDrawable().apply {
                colors = intArrayOf(Color.argb(238, 250, 251, 253), Color.argb(226, 239, 243, 249))
                orientation = GradientDrawable.Orientation.LEFT_RIGHT
            }
        }
        val dot = View(this).apply {
            background = rounded(if (connecting) Color.rgb(245, 158, 11) else Color.rgb(34, 197, 94), dp(4))
        }
        strip.addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)))
        val labels = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), 0, 0, 0)
        }
        statusHostText = label(hostName ?: "Connecting...", 15f, Color.rgb(15, 23, 42), bold = true)
        statusModeText = label(inputModeTitle(), 12f, Color.rgb(100, 116, 139))
        labels.addView(statusHostText)
        labels.addView(statusModeText)
        strip.addView(labels, LinearLayout.LayoutParams(0, wrap, 1f))
        strip.addView(iconButton("×", Color.rgb(220, 38, 38)) {
            transport?.disconnect()
        })
        return strip
    }

    private fun inputDock(): View {
        val dock = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(10), dp(16), dp(10))
        }
        val modBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(6), dp(8), dp(6))
            background = rounded(Color.argb(180, 28, 37, 53), dp(22), Color.argb(36, 255, 255, 255), 1)
        }
        val buttons = mutableMapOf<SoftModifier, Button>()
        SoftModifier.entries.forEach { modifier ->
            val button = Button(this).apply {
                text = modifier.symbol
                textSize = 18f
                isAllCaps = false
                minWidth = 0
                minHeight = 0
                setPadding(0, 0, 0, 0)
                setOnClickListener { toggleSoftModifier(modifier) }
            }
            buttons[modifier] = button
            modBar.addView(button, LinearLayout.LayoutParams(dp(46), dp(38)).withMargins(dp(4), 0, dp(4), 0))
        }
        modifierButtons = buttons
        dock.addView(modBar)
        dock.addView(Space(this), LinearLayout.LayoutParams(0, 1, 1f))
        dock.addView(iconButton("⌨", Color.WHITE) {
            wakeDock()
            val capture = findViewById<EditText>(SOFT_KEYBOARD_CAPTURE_ID)
            if (capture.hasFocus()) {
                capture.clearFocus()
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                    .hideSoftInputFromWindow(capture.windowToken, 0)
            } else {
                remoteSurface?.showSoftKeyboardFor(capture)
            }
        })
        refreshModifierButtons()
        return dock
    }

    private fun softKeyboardCapture(): EditText =
        EditText(this).apply {
            id = SOFT_KEYBOARD_CAPTURE_ID
            alpha = 0.01f
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setBackgroundColor(Color.TRANSPARENT)
            var internalChange = false
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable) {
                    if (internalChange || s.isEmpty()) return
                    val text = s.toString()
                    text.forEach { handleSoftCharacter(it.toString()) }
                    internalChange = true
                    s.clear()
                    internalChange = false
                }
            })
            setOnKeyListener { _, keyCode, event ->
                if (event.action != KeyEvent.ACTION_DOWN) return@setOnKeyListener false
                when (keyCode) {
                    KeyEvent.KEYCODE_DEL -> {
                        sendSoftKey(0x2A)
                        true
                    }

                    KeyEvent.KEYCODE_ENTER -> {
                        sendSoftKey(0x28)
                        true
                    }

                    else -> false
                }
            }
        }

    private fun handleSoftCharacter(text: String) {
        val shortcut = SoftKeyboardShortcutMapper.map(text, softModifierMask)
        if (shortcut != null && shortcut.modifiers != 0) {
            sendSoftKey(shortcut.usage, shortcut.modifiers)
        } else {
            transport?.send(ControlMessage.Text(text))
        }
    }

    private fun sendSoftKey(usage: Int, modifiers: Int = softModifierMask) {
        transport?.send(ControlMessage.Key(usage, true, modifiers))
        transport?.send(ControlMessage.Key(usage, false, modifiers))
    }

    private fun toggleSoftModifier(modifier: SoftModifier) {
        wakeDock()
        val active = softModifierMask and modifier.mask != 0
        if (active) {
            softModifierMask = softModifierMask and modifier.mask.inv()
            transport?.send(ControlMessage.Key(modifier.hidUsage, false, softModifierMask))
        } else {
            softModifierMask = softModifierMask or modifier.mask
            transport?.send(ControlMessage.Key(modifier.hidUsage, true, softModifierMask))
        }
        refreshModifierButtons()
    }

    private fun refreshModifierButtons() {
        modifierButtons.forEach { (modifier, button) ->
            val active = softModifierMask and modifier.mask != 0
            button.setTextColor(if (active) Color.WHITE else Color.argb(220, 241, 245, 249))
            button.background = rounded(
                if (active) Color.rgb(37, 99, 235) else Color.argb(46, 255, 255, 255),
                dp(9),
                Color.argb(if (active) 64 else 26, 255, 255, 255),
                1,
            )
        }
    }

    private fun renderEnded(reason: String) {
        lastScreen = Screen.Ended
        showSystemChrome()
        stopDiscovery()
        detachRemoteSurface()
        transport?.dispose()
        transport = null

        val root = centeredRoot()
        root.addView(label("Session ended", 23f, Color.rgb(15, 23, 42), bold = true, gravity = Gravity.CENTER))
        root.addView(label(reason, 15f, Color.rgb(100, 116, 139), gravity = Gravity.CENTER).withTop(8).withMaxWidth(dp(520)))
        root.addView(primaryButton("Pair again") {
            pairingError = null
            renderPairing()
        }.withTop(22).withMaxWidth(dp(260)))
        setContentView(root)
    }

    private fun startDiscovery() {
        if (discovery != null) return
        val nextDiscovery = LocalHostDiscovery(
            context = this,
            cloudKit = cloudKit,
            scope = this,
            onHostsChanged = {
                hosts = it
                // Don't rebuild the screen (and drop focus) while the user is
                // typing a pairing code; refresh only the device list.
                if (lastScreen == Screen.Pairing) {
                    if (codeEntry?.hasFocus() == true) refreshDeviceList() else renderPairing()
                }
            },
            onCloudKitError = {
                if (it is CloudKitException.MissingWebAuthToken || it is CloudKitException.AuthenticationFailed) {
                    tokenStore.clearLogin()
                    renderAuth(it.message, checking = false)
                }
            },
        )
        discovery = nextDiscovery
        nextDiscovery.start()
    }

    private fun stopDiscovery() {
        discovery?.stop()
        discovery = null
        hosts = emptyList()
    }

    private fun attachVideoIfReady() {
        if (videoAttached) return
        val surface = remoteSurface ?: return
        val activeTransport = transport ?: return
        videoAttached = true
        uiHandler.removeCallbacks(videoAttachFallback)
        activeTransport.attachVideoRenderer(surface.renderer)
    }

    private fun detachRemoteSurface() {
        uiHandler.removeCallbacks(hideChromeRunnable)
        uiHandler.removeCallbacks(dockIdleRunnable)
        uiHandler.removeCallbacks(videoAttachFallback)
        videoAttached = false
        statusStripView = null
        dragHandleView = null
        inputDockView = null
        remoteSurface?.let { surface ->
            transport?.detachVideoRenderer(surface.renderer)
            runCatching { surface.renderer.release() }
        }
        remoteSurface = null
    }

    private fun updateSessionStatus() {
        statusHostText?.text = hostName ?: "Connecting..."
        statusModeText?.text = inputModeTitle()
    }

    private fun inputModeTitle(): String =
        "Touch cursor and soft keys"

    private fun centeredRoot(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(28), dp(28), dp(28), dp(28))
            setBackgroundColor(Color.rgb(243, 245, 247))
        }

    private fun cardContainer(): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(18))
            background = rounded(Color.argb(238, 255, 255, 255), dp(22), Color.argb(26, 15, 23, 42), 1)
            elevation = dp(4).toFloat()
        }

    private fun sectionHeader(title: String, count: Int?): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        row.addView(label(title, 17f, Color.rgb(15, 23, 42), bold = true), LinearLayout.LayoutParams(0, wrap, 1f))
        if (count == null) {
            row.addView(ProgressBar(this).apply { isIndeterminate = true }, LinearLayout.LayoutParams(dp(24), dp(24)))
        } else {
            row.addView(
                label(count.toString(), 12f, Color.rgb(86, 96, 112), bold = true, gravity = Gravity.CENTER).apply {
                    setPadding(dp(9), dp(4), dp(9), dp(4))
                    background = rounded(Color.rgb(239, 242, 247), dp(12))
                }
            )
        }
        return row
    }

    private fun rowButton(
        title: String,
        accessory: String,
        subtitle: String? = null,
        action: () -> Unit,
    ): View {
        val button = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true
            isFocusable = true
            setPadding(dp(16), dp(14), dp(14), dp(14))
            background = rounded(Color.rgb(246, 248, 251), dp(16), Color.argb(18, 15, 23, 42), 1)
            setOnClickListener { action() }
        }
        button.addView(LogoDotView(this), LinearLayout.LayoutParams(dp(42), dp(42)))
        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), 0, 0, 0)
        }
        texts.addView(label(title, 16f, Color.rgb(15, 23, 42), bold = true))
        subtitle?.let { texts.addView(label(it, 13f, Color.rgb(100, 116, 139)).withTop(2)) }
        button.addView(texts, LinearLayout.LayoutParams(0, wrap, 1f))
        button.addView(label(accessory, 24f, Color.rgb(100, 116, 139), gravity = Gravity.CENTER))
        return button
    }

    private fun errorBanner(message: String): TextView =
        label(message, 14f, Color.rgb(190, 18, 60)).apply {
            setPadding(dp(14), dp(12), dp(14), dp(12))
            background = rounded(Color.rgb(254, 242, 242), dp(12), Color.argb(46, 220, 38, 38), 1)
        }

    private fun primaryButton(text: String, action: () -> Unit): Button =
        Button(this).apply {
            this.text = text
            textSize = 16f
            isAllCaps = false
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            background = rounded(Color.rgb(37, 99, 235), dp(12))
            minHeight = dp(52)
            setOnClickListener { action() }
        }

    private fun plainButton(text: String, action: () -> Unit): Button =
        Button(this).apply {
            this.text = text
            textSize = 14f
            isAllCaps = false
            setTextColor(Color.rgb(37, 99, 235))
            background = rounded(Color.TRANSPARENT, dp(10))
            setOnClickListener { action() }
        }

    private fun iconButton(text: String, color: Int, action: () -> Unit): Button =
        Button(this).apply {
            this.text = text
            textSize = 23f
            isAllCaps = false
            minWidth = 0
            minHeight = 0
            setTextColor(color)
            background = rounded(Color.argb(82, 255, 255, 255), dp(26), Color.argb(42, 255, 255, 255), 1)
            setPadding(0, 0, 0, 0)
            setOnClickListener { action() }
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52))
        }

    private fun label(
        text: String,
        size: Float,
        color: Int,
        bold: Boolean = false,
        gravity: Int = Gravity.START,
    ): TextView =
        TextView(this).apply {
            this.text = text
            textSize = size
            setTextColor(color)
            this.gravity = gravity
            includeFontPadding = true
            if (bold) typeface = Typeface.DEFAULT_BOLD
        }

    private fun hideSystemChrome() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    private fun showSystemChrome() {
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun View.withTop(margin: Int): View = apply {
        val current = layoutParams as? LinearLayout.LayoutParams
        layoutParams = (current ?: LinearLayout.LayoutParams(match, wrap)).apply {
            topMargin = margin
        }
    }

    /// Centers [this] and caps its width at [maxWidth] without ever exceeding
    /// the available width — so content never overflows narrow screens (the
    /// old fixed-width approach clipped both edges on phones).
    private fun View.withMaxWidth(maxWidth: Int): View {
        val topMargin = (layoutParams as? LinearLayout.LayoutParams)?.topMargin ?: 0
        layoutParams = FrameLayout.LayoutParams(match, wrap, Gravity.CENTER_HORIZONTAL)
        val inner = this
        val wrapper = object : FrameLayout(this@MainActivity) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val available = MeasureSpec.getSize(widthMeasureSpec)
                val target = if (available > 0) minOf(available, maxWidth) else maxWidth
                super.onMeasure(
                    MeasureSpec.makeMeasureSpec(target, MeasureSpec.EXACTLY),
                    heightMeasureSpec,
                )
            }
        }
        wrapper.addView(inner)
        wrapper.layoutParams = LinearLayout.LayoutParams(match, wrap).apply {
            this.topMargin = topMargin
            gravity = Gravity.CENTER_HORIZONTAL
        }
        return wrapper
    }

    private fun LinearLayout.LayoutParams.withMargins(left: Int, top: Int, right: Int, bottom: Int): LinearLayout.LayoutParams =
        apply { setMargins(left, top, right, bottom) }

    private fun solid(color: Int): GradientDrawable =
        GradientDrawable().apply { setColor(color) }

    private fun rounded(
        color: Int,
        radius: Int,
        strokeColor: Int? = null,
        strokeWidth: Int = 0,
    ): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius.toFloat()
            if (strokeColor != null && strokeWidth > 0) setStroke(strokeWidth, strokeColor)
        }

    private fun verticalGradient(top: Int, bottom: Int): GradientDrawable =
        GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(top, bottom))

    private enum class Screen { Auth, Pairing, Session, Ended }

    companion object {
        private const val TAG = "RemoteDesktop"
        private const val match = ViewGroup.LayoutParams.MATCH_PARENT
        private const val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        private const val SOFT_KEYBOARD_CAPTURE_ID = 0x220781
    }
}
