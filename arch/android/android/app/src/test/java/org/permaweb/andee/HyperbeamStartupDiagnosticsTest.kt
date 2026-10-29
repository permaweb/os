package org.permaweb.andee

import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HyperbeamStartupDiagnosticsTest {
    @get:Rule val temp = TemporaryFolder()

    private fun dump(diagnostics: HyperbeamStartupDiagnostics, enabled: Boolean = true,
                     args: Array<String> = arrayOf("--runtime-logs")): Pair<Boolean, String> {
        val text = StringWriter()
        val result = diagnostics.dump(enabled, args, PrintWriter(text))
        return result to text.toString()
    }

    @Test fun defaultAndImplicitDumpNeverExposeLogs() {
        val diagnostics = HyperbeamStartupDiagnostics(temp.root)
        File(temp.root, "hyperbeam.stderr").writeText("private startup detail")
        assertEquals(false to "", dump(diagnostics, enabled = false))
        assertEquals(false to "", dump(diagnostics, args = emptyArray()))
        assertEquals(false to "", dump(diagnostics, args = arrayOf("--runtime-logs", "/other-file")))
    }

    @Test fun excludesPreviousLaunchAndNeverWritesLogs() {
        val out = File(temp.root, "hyperbeam.stdout").apply { writeText("old launch secret\n") }
        val diagnostics = HyperbeamStartupDiagnostics(temp.root)
        out.appendText("andee-bootstrap=start-http\n")
        val before = out.readBytes()
        val (handled, text) = dump(diagnostics)
        assertTrue(handled)
        assertTrue(text.contains("andee-bootstrap=start-http"))
        assertFalse(text.contains("old launch secret"))
        assertArrayEquals(before, out.readBytes())
    }

    @Test fun boundsEachCurrentLaunchTail() {
        val diagnostics = HyperbeamStartupDiagnostics(temp.root)
        File(temp.root, "hyperbeam.stderr").writeText("omit-me" + "x".repeat(20000) + "current-failure")
        val text = dump(diagnostics).second
        assertFalse(text.contains("omit-me"))
        assertTrue(text.contains("current-failure"))
        assertTrue(text.contains("earlier launch output omitted"))
        assertTrue(text.length < HyperbeamStartupDiagnostics.MAX_LOG_BYTES + 600)
    }

    @Test fun missingOrTruncatedLogsRemainUnavailable() {
        val out = File(temp.root, "hyperbeam.stdout").apply { writeText("previous data") }
        val diagnostics = HyperbeamStartupDiagnostics(temp.root)
        out.writeText("new")
        val text = dump(diagnostics).second
        assertTrue(text.contains("log was truncated after launch"))
        assertTrue(text.contains("unavailable"))
        assertFalse(text.contains("\nnew\n"))
    }

    @Test fun reportsActualChildExitWithoutRestartingIt() {
        val diagnostics = HyperbeamStartupDiagnostics(temp.root)
        val child = ProcessBuilder("sh", "-c", "exit 37").start()
        diagnostics.process = child
        assertEquals(37, child.waitFor())
        val text = dump(diagnostics).second
        assertTrue(text.contains("alive=false"))
        assertTrue(text.contains("exit-code=37"))
        assertFalse(child.isAlive)
    }
}
