package com.threadmark.remotedesktop

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import org.webrtc.EglBase
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class RemoteScreenSurface(context: Context) : FrameLayout(context) {
    val renderer = SurfaceViewRenderer(context)
    var displayInfo: DisplayInfo? = null
        set(value) {
            field = value
            requestLayout()
            invalidate()
        }

    // Actual rotated resolution of the incoming video, reported by WebRTC.
    // Used to lay out the renderer and map the cursor so both match the
    // real frame instead of the (possibly stale) display advertisement.
    private var frameWidth = 0
    private var frameHeight = 0
    var onPointer: ((x: Int, y: Int, buttons: Int) -> Unit)? = null
    var onScroll: ((x: Int, y: Int, dx: Int, dy: Int, phase: ScrollPhase) -> Unit)? = null

    // Fires once the renderer has been laid out at the correct (aspect-fitted)
    // size, so video frames can be attached without a later resize that would
    // blank a static remote screen. See MainActivity.attachVideoIfReady.
    var onVideoReady: (() -> Unit)? = null
    private var videoReadyFired = false

    private val cursorPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        style = Paint.Style.FILL
        setShadowLayer(8f, 0f, 2f, Color.argb(180, 0, 0, 0))
    }
    private val cursorStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(210, 37, 99, 235)
        style = Paint.Style.STROKE
        strokeWidth = 3f
    }
    private val handler = Handler(Looper.getMainLooper())
    private val longPressRunnable = Runnable {
        longPressFired = true
        sendPointer(cursorX, cursorY, 0b010)
        sendPointer(cursorX, cursorY, 0)
    }
    private var cursorX = 0f
    private var cursorY = 0f
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var touchStartX = 0f
    private var touchStartY = 0f
    private var touchStartTime = 0L
    private var activePointerId = -1
    private var moved = false
    private var longPressFired = false
    private var lastSentPointer: Triple<Int, Int, Int>? = null
    private var lastScrollX = 0f
    private var lastScrollY = 0f
    private var touchScrollActive = false

    init {
        setWillNotDraw(false)
        isFocusable = true
        isFocusableInTouchMode = true
        setBackgroundColor(Color.BLACK)
        renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        renderer.setEnableHardwareScaler(true)
        // The renderer view is sized to the frame's aspect ratio in onLayout
        // (centered). WebRTC's EglRenderer crops to whatever aspect the *view*
        // has, so a full-bleed (MATCH_PARENT) view would zoom/crop; matching the
        // view aspect to the frame aspect makes it letterbox-fit instead.
        addView(
            renderer,
            LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.CENTER,
            ),
        )
    }

    /// Initializes the GL renderer and subscribes to frame-resolution
    /// changes so the surface always knows the real video aspect ratio.
    fun initRenderer(eglContext: EglBase.Context) {
        renderer.init(eglContext, rendererEvents)
    }

    private val rendererEvents = object : RendererCommon.RendererEvents {
        override fun onFirstFrameRendered() = Unit

        override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
            post {
                val rotated = rotation % 180 != 0
                frameWidth = if (rotated) videoHeight else videoWidth
                frameHeight = if (rotated) videoWidth else videoHeight
                requestLayout()
                invalidate()
            }
        }
    }

    fun showSoftKeyboardFor(captureView: android.view.View) {
        captureView.requestFocus()
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(captureView, InputMethodManager.SHOW_IMPLICIT)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (cursorX == 0f && cursorY == 0f) {
            cursorX = w / 2f
            cursorY = h / 2f
        }
        clampCursor()
        invalidate()
    }

    // Sizes and positions the renderer to the aspect-fitted, centered rect on
    // every layout pass. Doing this from onLayout (rather than cached layout
    // params) keeps the video correct across window resizes such as folding a
    // foldable, and matches the cursor's interactiveRect exactly.
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        val rect = fittedRect(w, h)
        renderer.measure(
            MeasureSpec.makeMeasureSpec(rect.width().roundToInt(), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(rect.height().roundToInt(), MeasureSpec.EXACTLY),
        )
        setMeasuredDimension(w, h)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val rect = fittedRect(r - l, b - t)
        renderer.layout(
            rect.left.roundToInt(),
            rect.top.roundToInt(),
            rect.right.roundToInt(),
            rect.bottom.roundToInt(),
        )
        clampCursor()
        if (!videoReadyFired && videoAspect() > 0f && renderer.width > 0) {
            videoReadyFired = true
            post { onVideoReady?.invoke() }
        }
    }

    private fun fittedRect(w: Int, h: Int): RectF {
        val aspect = videoAspect()
        if (aspect <= 0f || w <= 0 || h <= 0) {
            return RectF(0f, 0f, w.toFloat(), h.toFloat())
        }
        val boundsAspect = w.toFloat() / h.toFloat()
        return if (aspect > boundsAspect) {
            val fittedHeight = w / aspect
            RectF(0f, (h - fittedHeight) / 2f, w.toFloat(), (h + fittedHeight) / 2f)
        } else {
            val fittedWidth = h * aspect
            RectF((w - fittedWidth) / 2f, 0f, (w + fittedWidth) / 2f, h.toFloat())
        }
    }

    private fun videoAspect(): Float {
        if (frameWidth > 0 && frameHeight > 0) {
            return frameWidth.toFloat() / frameHeight.toFloat()
        }
        val display = displayInfo
        if (display != null && display.width > 0 && display.height > 0) {
            return display.width.toFloat() / display.height.toFloat()
        }
        return 0f
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (!event.isFromSource(android.view.InputDevice.SOURCE_MOUSE) &&
            !event.isFromSource(android.view.InputDevice.SOURCE_TOUCHPAD)
        ) {
            return super.onGenericMotionEvent(event)
        }

        return when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_MOVE -> {
                cursorX = event.x
                cursorY = event.y
                clampCursor()
                sendPointer(cursorX, cursorY, buttonsFrom(event.buttonState))
                invalidate()
                true
            }

            MotionEvent.ACTION_SCROLL -> {
                cursorX = event.x
                cursorY = event.y
                clampCursor()
                val dx = (-event.getAxisValue(MotionEvent.AXIS_HSCROLL) * 64f).roundToInt()
                val dy = (-event.getAxisValue(MotionEvent.AXIS_VSCROLL) * 64f).roundToInt()
                sendScroll(cursorX, cursorY, dx, dy, ScrollPhase.Changed)
                true
            }

            else -> super.onGenericMotionEvent(event)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        requestFocus()

        if (event.isFromSource(android.view.InputDevice.SOURCE_MOUSE)) {
            cursorX = event.x
            cursorY = event.y
            clampCursor()
            sendPointer(cursorX, cursorY, buttonsFrom(event.buttonState))
            invalidate()
            return true
        }

        if (event.pointerCount >= 2) {
            handleTouchScroll(event)
            return true
        } else if (touchScrollActive) {
            sendScroll(cursorX, cursorY, 0, 0, ScrollPhase.End)
            touchScrollActive = false
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                activePointerId = event.getPointerId(0)
                lastTouchX = event.x
                lastTouchY = event.y
                touchStartX = event.x
                touchStartY = event.y
                touchStartTime = event.eventTime
                moved = false
                longPressFired = false
                ensureCursorInitialized(event.x, event.y)
                handler.postDelayed(longPressRunnable, 450L)
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(activePointerId)
                if (index < 0) return true
                val x = event.getX(index)
                val y = event.getY(index)
                val dx = (x - lastTouchX) * 1.2f
                val dy = (y - lastTouchY) * 1.2f
                cursorX += dx
                cursorY += dy
                clampCursor()
                if (abs(x - touchStartX) > 8f || abs(y - touchStartY) > 8f) {
                    moved = true
                    handler.removeCallbacks(longPressRunnable)
                }
                lastTouchX = x
                lastTouchY = y
                sendPointer(cursorX, cursorY, 0)
                invalidate()
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(longPressRunnable)
                val duration = event.eventTime - touchStartTime
                if (!moved && !longPressFired && duration < 250L) {
                    sendPointer(cursorX, cursorY, 0b001)
                    sendPointer(cursorX, cursorY, 0)
                }
                activePointerId = -1
                invalidate()
                return true
            }
        }
        return true
    }

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        if (width == 0 || height == 0) return
        canvas.drawCircle(cursorX, cursorY, 9f, cursorPaint)
        canvas.drawCircle(cursorX, cursorY, 10.5f, cursorStrokePaint)
    }

    private fun handleTouchScroll(event: MotionEvent) {
        val x = (event.getX(0) + event.getX(1)) / 2f
        val y = (event.getY(0) + event.getY(1)) / 2f
        when (event.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_DOWN -> {
                lastScrollX = x
                lastScrollY = y
                touchScrollActive = true
                sendScroll(cursorX, cursorY, 0, 0, ScrollPhase.Begin)
            }

            MotionEvent.ACTION_MOVE -> {
                if (!touchScrollActive) {
                    touchScrollActive = true
                    sendScroll(cursorX, cursorY, 0, 0, ScrollPhase.Begin)
                }
                val dx = (x - lastScrollX).roundToInt()
                val dy = (y - lastScrollY).roundToInt()
                lastScrollX = x
                lastScrollY = y
                sendScroll(cursorX, cursorY, dx, dy, ScrollPhase.Changed)
            }

            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                sendScroll(cursorX, cursorY, 0, 0, ScrollPhase.End)
                touchScrollActive = false
            }
        }
    }

    private fun ensureCursorInitialized(fallbackX: Float, fallbackY: Float) {
        if (cursorX == 0f && cursorY == 0f) {
            cursorX = fallbackX
            cursorY = fallbackY
            clampCursor()
        }
    }

    private fun buttonsFrom(buttonState: Int): Int {
        var buttons = 0
        if (buttonState and MotionEvent.BUTTON_PRIMARY != 0) buttons = buttons or 0b001
        if (buttonState and MotionEvent.BUTTON_SECONDARY != 0) buttons = buttons or 0b010
        if (buttonState and MotionEvent.BUTTON_TERTIARY != 0) buttons = buttons or 0b100
        return buttons
    }

    private fun sendPointer(localX: Float, localY: Float, buttons: Int) {
        val remote = localToRemote(localX, localY)
        val key = Triple(remote.first, remote.second, buttons)
        if (lastSentPointer == key) return
        lastSentPointer = key
        onPointer?.invoke(remote.first, remote.second, buttons)
    }

    private fun sendScroll(localX: Float, localY: Float, dx: Int, dy: Int, phase: ScrollPhase) {
        if (dx == 0 && dy == 0 && phase == ScrollPhase.Changed) return
        val remote = localToRemote(localX, localY)
        onScroll?.invoke(remote.first, remote.second, dx, dy, phase)
    }

    private fun clampCursor() {
        val rect = interactiveRect()
        cursorX = min(rect.right, max(rect.left, cursorX))
        cursorY = min(rect.bottom, max(rect.top, cursorY))
    }

    private fun localToRemote(x: Float, y: Float): Pair<Int, Int> {
        val display = displayInfo ?: return x.roundToInt() to y.roundToInt()
        val rect = interactiveRect()
        val clampedX = min(rect.right, max(rect.left, x))
        val clampedY = min(rect.bottom, max(rect.top, y))
        val nx = if (rect.width() > 0f) (clampedX - rect.left) / rect.width() else 0f
        val ny = if (rect.height() > 0f) (clampedY - rect.top) / rect.height() else 0f
        val maxX = max(display.width - 1, 0)
        val maxY = max(display.height - 1, 0)
        return (nx * maxX).roundToInt() to (ny * maxY).roundToInt()
    }

    // The same aspect-fitted rect the renderer is laid out to (see fittedRect),
    // computed from the live view size + real frame aspect — so the cursor's
    // interactive area always matches the rendered video in any orientation.
    private fun interactiveRect(): RectF {
        val aspect = videoAspect()
        if (aspect <= 0f || width <= 0 || height <= 0) {
            return RectF(0f, 0f, width.toFloat(), height.toFloat())
        }
        val boundsAspect = width.toFloat() / height.toFloat()
        return if (aspect > boundsAspect) {
            val fittedHeight = width / aspect
            RectF(0f, (height - fittedHeight) / 2f, width.toFloat(), (height + fittedHeight) / 2f)
        } else {
            val fittedWidth = height * aspect
            RectF((width - fittedWidth) / 2f, 0f, (width + fittedWidth) / 2f, height.toFloat())
        }
    }
}
