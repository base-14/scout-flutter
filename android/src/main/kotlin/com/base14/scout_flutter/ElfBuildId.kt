package com.base14.scout_flutter

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Reads the GNU build-id (NT_GNU_BUILD_ID) from an ELF shared object.
 *
 * This is the identity the symbolizer matches native (Android NDK) frames by —
 * the ELF analog of an iOS dSYM UUID. The crash signal handler only captures
 * each image's base + path (async-signal-safe); the build-id is recovered here,
 * at report-assembly time on a normal thread (see [CrashReporter.getPendingCrashReports]),
 * by reading the still-on-disk `.so`. Returns the lowercase hex build-id, or null
 * if the file is missing/unreadable or carries no build-id note.
 */
internal object ElfBuildId {
    private const val PT_NOTE = 4
    private const val NT_GNU_BUILD_ID = 3

    fun read(path: String): String? {
        val file = File(path)
        if (!file.isFile || !file.canRead()) return null
        return try {
            RandomAccessFile(file, "r").use { f -> parse(f) }
        } catch (_: Exception) {
            null
        }
    }

    private fun parse(f: RandomAccessFile): String? {
        if (f.length() < 64) return null
        val ident = ByteArray(16)
        f.seek(0)
        f.readFully(ident)
        if (ident[0] != 0x7f.toByte() || ident[1] != 'E'.code.toByte() ||
            ident[2] != 'L'.code.toByte() || ident[3] != 'F'.code.toByte()
        ) {
            return null
        }
        val is64 = ident[4].toInt() == 2
        val order = if (ident[5].toInt() == 1) ByteOrder.LITTLE_ENDIAN else ByteOrder.BIG_ENDIAN

        val phoff: Long
        val phentsize: Int
        val phnum: Int
        if (is64) {
            f.seek(32); phoff = readLong(f, order)
            f.seek(54); phentsize = readShort(f, order); phnum = readShort(f, order)
        } else {
            f.seek(28); phoff = readInt(f, order).toLong() and 0xffffffffL
            f.seek(42); phentsize = readShort(f, order); phnum = readShort(f, order)
        }

        for (i in 0 until phnum) {
            val ph = phoff + i.toLong() * phentsize
            f.seek(ph)
            if (readInt(f, order) != PT_NOTE) continue
            val pOffset: Long
            val pFilesz: Long
            if (is64) {
                f.seek(ph + 8); pOffset = readLong(f, order)
                f.seek(ph + 32); pFilesz = readLong(f, order)
            } else {
                f.seek(ph + 4); pOffset = readInt(f, order).toLong() and 0xffffffffL
                f.seek(ph + 20); pFilesz = readInt(f, order).toLong() and 0xffffffffL
            }
            scanNotes(f, order, pOffset, pFilesz)?.let { return it }
        }
        return null
    }

    private fun scanNotes(f: RandomAccessFile, order: ByteOrder, offset: Long, size: Long): String? {
        var pos = offset
        val end = offset + size
        while (pos + 12 <= end) {
            f.seek(pos)
            val namesz = readInt(f, order)
            val descsz = readInt(f, order)
            val type = readInt(f, order)
            if (namesz < 0 || descsz < 0 || namesz > 64 || descsz > 256) return null
            val nameStart = pos + 12
            val descStart = nameStart + align4(namesz)
            if (type == NT_GNU_BUILD_ID && namesz >= 3) {
                val name = ByteArray(namesz)
                f.seek(nameStart); f.readFully(name)
                if (name[0] == 'G'.code.toByte() && name[1] == 'N'.code.toByte() && name[2] == 'U'.code.toByte()) {
                    val desc = ByteArray(descsz)
                    f.seek(descStart); f.readFully(desc)
                    return desc.joinToString("") { "%02x".format(it.toInt() and 0xff) }
                }
            }
            pos = descStart + align4(descsz)
        }
        return null
    }

    private fun align4(n: Int): Long = (n.toLong() + 3) and 3L.inv()

    private fun readLong(f: RandomAccessFile, order: ByteOrder): Long {
        val b = ByteArray(8); f.readFully(b); return ByteBuffer.wrap(b).order(order).long
    }

    private fun readInt(f: RandomAccessFile, order: ByteOrder): Int {
        val b = ByteArray(4); f.readFully(b); return ByteBuffer.wrap(b).order(order).int
    }

    private fun readShort(f: RandomAccessFile, order: ByteOrder): Int {
        val b = ByteArray(2); f.readFully(b); return ByteBuffer.wrap(b).order(order).short.toInt() and 0xffff
    }
}
