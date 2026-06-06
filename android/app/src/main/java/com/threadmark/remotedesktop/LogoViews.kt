package com.threadmark.remotedesktop

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

class LogoView(context: Context) : View(context) {
    private val plate = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val screen = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(37, 99, 235) }
    private val glass = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(232, 255, 255, 255) }
    private val stand = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(52, 15, 23, 42) }
    private val highlight = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(90, 255, 255, 255) }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val size = width.coerceAtMost(height).toFloat()
        val left = (width - size) / 2f
        val top = (height - size) / 2f
        val radius = size * 0.26f
        canvas.drawRoundRect(RectF(left, top, left + size, top + size), radius, radius, plate)

        val monitor = RectF(
            left + size * 0.18f,
            top + size * 0.25f,
            left + size * 0.82f,
            top + size * 0.68f,
        )
        canvas.drawRoundRect(monitor, size * 0.07f, size * 0.07f, screen)
        canvas.drawRect(
            monitor.left + size * 0.07f,
            monitor.top + size * 0.08f,
            monitor.right - size * 0.07f,
            monitor.bottom - size * 0.1f,
            glass,
        )
        canvas.drawRect(left + size * 0.43f, top + size * 0.68f, left + size * 0.57f, top + size * 0.79f, stand)
        canvas.drawRoundRect(
            RectF(left + size * 0.34f, top + size * 0.78f, left + size * 0.66f, top + size * 0.84f),
            size * 0.03f,
            size * 0.03f,
            stand,
        )
        canvas.drawRect(
            monitor.left + size * 0.11f,
            monitor.top + size * 0.13f,
            monitor.right - size * 0.18f,
            monitor.top + size * 0.18f,
            highlight,
        )
    }
}

class LogoDotView(context: Context) : View(context) {
    private val circle = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(31, 37, 99, 235) }
    private val monitor = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(37, 99, 235) }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val size = width.coerceAtMost(height).toFloat()
        val cx = width / 2f
        val cy = height / 2f
        canvas.drawCircle(cx, cy, size * 0.5f, circle)
        val rect = RectF(cx - size * 0.24f, cy - size * 0.16f, cx + size * 0.24f, cy + size * 0.13f)
        canvas.drawRoundRect(rect, size * 0.045f, size * 0.045f, monitor)
        canvas.drawRect(cx - size * 0.06f, cy + size * 0.13f, cx + size * 0.06f, cy + size * 0.22f, monitor)
    }
}
