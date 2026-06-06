package com.threadmark.remotedesktop

import android.view.KeyEvent

object HidKeyMapper {
    fun usageForKeyCode(keyCode: Int): Int? = when (keyCode) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> 0x04 + (keyCode - KeyEvent.KEYCODE_A)
        in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9 -> 0x1E + (keyCode - KeyEvent.KEYCODE_1)
        KeyEvent.KEYCODE_0 -> 0x27
        KeyEvent.KEYCODE_ENTER -> 0x28
        KeyEvent.KEYCODE_ESCAPE -> 0x29
        KeyEvent.KEYCODE_DEL -> 0x2A
        KeyEvent.KEYCODE_TAB -> 0x2B
        KeyEvent.KEYCODE_SPACE -> 0x2C
        KeyEvent.KEYCODE_MINUS -> 0x2D
        KeyEvent.KEYCODE_EQUALS -> 0x2E
        KeyEvent.KEYCODE_LEFT_BRACKET -> 0x2F
        KeyEvent.KEYCODE_RIGHT_BRACKET -> 0x30
        KeyEvent.KEYCODE_BACKSLASH -> 0x31
        KeyEvent.KEYCODE_SEMICOLON -> 0x33
        KeyEvent.KEYCODE_APOSTROPHE -> 0x34
        KeyEvent.KEYCODE_GRAVE -> 0x35
        KeyEvent.KEYCODE_COMMA -> 0x36
        KeyEvent.KEYCODE_PERIOD -> 0x37
        KeyEvent.KEYCODE_SLASH -> 0x38
        KeyEvent.KEYCODE_CAPS_LOCK -> 0x39
        KeyEvent.KEYCODE_F1 -> 0x3A
        KeyEvent.KEYCODE_F2 -> 0x3B
        KeyEvent.KEYCODE_F3 -> 0x3C
        KeyEvent.KEYCODE_F4 -> 0x3D
        KeyEvent.KEYCODE_F5 -> 0x3E
        KeyEvent.KEYCODE_F6 -> 0x3F
        KeyEvent.KEYCODE_F7 -> 0x40
        KeyEvent.KEYCODE_F8 -> 0x41
        KeyEvent.KEYCODE_F9 -> 0x42
        KeyEvent.KEYCODE_F10 -> 0x43
        KeyEvent.KEYCODE_F11 -> 0x44
        KeyEvent.KEYCODE_F12 -> 0x45
        KeyEvent.KEYCODE_SYSRQ -> 0x46
        KeyEvent.KEYCODE_SCROLL_LOCK -> 0x47
        KeyEvent.KEYCODE_BREAK -> 0x48
        KeyEvent.KEYCODE_INSERT -> 0x49
        KeyEvent.KEYCODE_MOVE_HOME -> 0x4A
        KeyEvent.KEYCODE_PAGE_UP -> 0x4B
        KeyEvent.KEYCODE_FORWARD_DEL -> 0x4C
        KeyEvent.KEYCODE_MOVE_END -> 0x4D
        KeyEvent.KEYCODE_PAGE_DOWN -> 0x4E
        KeyEvent.KEYCODE_DPAD_RIGHT -> 0x4F
        KeyEvent.KEYCODE_DPAD_LEFT -> 0x50
        KeyEvent.KEYCODE_DPAD_DOWN -> 0x51
        KeyEvent.KEYCODE_DPAD_UP -> 0x52
        KeyEvent.KEYCODE_CTRL_LEFT -> 0xE0
        KeyEvent.KEYCODE_SHIFT_LEFT -> 0xE1
        KeyEvent.KEYCODE_ALT_LEFT -> 0xE2
        KeyEvent.KEYCODE_META_LEFT -> 0xE3
        KeyEvent.KEYCODE_CTRL_RIGHT -> 0xE4
        KeyEvent.KEYCODE_SHIFT_RIGHT -> 0xE5
        KeyEvent.KEYCODE_ALT_RIGHT -> 0xE6
        KeyEvent.KEYCODE_META_RIGHT -> 0xE7
        else -> null
    }

    fun modifierMask(event: KeyEvent, extraSoftMask: Int = 0): Int {
        var mask = extraSoftMask
        if (event.metaState and KeyEvent.META_SHIFT_LEFT_ON != 0) mask = mask or (1 shl 0)
        if (event.metaState and KeyEvent.META_CTRL_LEFT_ON != 0) mask = mask or (1 shl 1)
        if (event.metaState and KeyEvent.META_ALT_LEFT_ON != 0) mask = mask or (1 shl 2)
        if (event.metaState and KeyEvent.META_META_LEFT_ON != 0) mask = mask or (1 shl 3)
        if (event.metaState and KeyEvent.META_SHIFT_RIGHT_ON != 0) mask = mask or (1 shl 4)
        if (event.metaState and KeyEvent.META_CTRL_RIGHT_ON != 0) mask = mask or (1 shl 5)
        if (event.metaState and KeyEvent.META_ALT_RIGHT_ON != 0) mask = mask or (1 shl 6)
        if (event.metaState and KeyEvent.META_META_RIGHT_ON != 0) mask = mask or (1 shl 7)
        if (event.metaState and KeyEvent.META_CAPS_LOCK_ON != 0) mask = mask or (1 shl 8)
        return mask
    }
}

data class SoftKeyboardShortcut(val usage: Int, val modifiers: Int)

object SoftKeyboardShortcutMapper {
    fun map(text: String, baseModifiers: Int): SoftKeyboardShortcut? {
        if (text.length != 1) return null
        val char = text[0]
        if (char.code > 127) return null

        if (char.isLetter()) {
            val lower = char.lowercaseChar()
            val usage = 0x04 + (lower.code - 'a'.code)
            val extra = if (char.isUpperCase()) SoftModifier.Shift.mask else 0
            return SoftKeyboardShortcut(usage, baseModifiers or extra)
        }

        punctuation[char]?.let { (usage, extra) ->
            return SoftKeyboardShortcut(usage, baseModifiers or extra)
        }

        return when (char) {
            in '1'..'9' -> SoftKeyboardShortcut(0x1E + (char.code - '1'.code), baseModifiers)
            '0' -> SoftKeyboardShortcut(0x27, baseModifiers)
            else -> null
        }
    }

    private val punctuation = mapOf(
        ' ' to (0x2C to 0),
        '-' to (0x2D to 0),
        '_' to (0x2D to SoftModifier.Shift.mask),
        '=' to (0x2E to 0),
        '+' to (0x2E to SoftModifier.Shift.mask),
        '[' to (0x2F to 0),
        '{' to (0x2F to SoftModifier.Shift.mask),
        ']' to (0x30 to 0),
        '}' to (0x30 to SoftModifier.Shift.mask),
        '\\' to (0x31 to 0),
        '|' to (0x31 to SoftModifier.Shift.mask),
        ';' to (0x33 to 0),
        ':' to (0x33 to SoftModifier.Shift.mask),
        '\'' to (0x34 to 0),
        '"' to (0x34 to SoftModifier.Shift.mask),
        '`' to (0x35 to 0),
        '~' to (0x35 to SoftModifier.Shift.mask),
        ',' to (0x36 to 0),
        '<' to (0x36 to SoftModifier.Shift.mask),
        '.' to (0x37 to 0),
        '>' to (0x37 to SoftModifier.Shift.mask),
        '/' to (0x38 to 0),
        '?' to (0x38 to SoftModifier.Shift.mask),
        '!' to (0x1E to SoftModifier.Shift.mask),
        '@' to (0x1F to SoftModifier.Shift.mask),
        '#' to (0x20 to SoftModifier.Shift.mask),
        '$' to (0x21 to SoftModifier.Shift.mask),
        '%' to (0x22 to SoftModifier.Shift.mask),
        '^' to (0x23 to SoftModifier.Shift.mask),
        '&' to (0x24 to SoftModifier.Shift.mask),
        '*' to (0x25 to SoftModifier.Shift.mask),
        '(' to (0x26 to SoftModifier.Shift.mask),
        ')' to (0x27 to SoftModifier.Shift.mask),
    )
}
