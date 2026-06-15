package com.base14.scout_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import java.io.File
import org.junit.Test

class ElfBuildIdTest {

    /** Materialize the committed ELF .so test resource to a temp file path. */
    private fun fixtureSo(): String {
        val bytes = javaClass.classLoader!!.getResourceAsStream("libapp.so")!!.readBytes()
        val tmp = File.createTempFile("libapp", ".so")
        tmp.deleteOnExit()
        tmp.writeBytes(bytes)
        return tmp.absolutePath
    }

    @Test
    fun readsGnuBuildIdFromElfSharedObject() {
        // The fixture is built with `-Wl,--build-id=sha1`; its build-id is fixed.
        assertEquals("d5df6ab2ce9300cb481861b7b6e12bceb1fb107a", ElfBuildId.read(fixtureSo()))
    }

    @Test
    fun returnsNullForMissingFile() {
        assertNull(ElfBuildId.read("/no/such/path/libmissing.so"))
    }

    @Test
    fun returnsNullForNonElfFile() {
        val tmp = File.createTempFile("notelf", ".so")
        tmp.deleteOnExit()
        tmp.writeText("this is not an ELF file, just some text padding to exceed the header size check ....")
        assertNull(ElfBuildId.read(tmp.absolutePath))
    }
}
