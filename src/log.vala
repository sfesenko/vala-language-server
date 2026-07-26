/* log.vala
 *
 * Structured logging for VLS: thread identification, NDC (Nested Diagnostic
 * Context) stack, optional per-scope timing, and trace-level filtering.
 *
 * Copyright 2026 Sergii Fesenko
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/**
 * Structured logging with thread identification, NDC stack, and timing.
 *
 * All methods are static and thread-safe. Thread-local state (thread name,
 * NDC stack) is stored in GLib.Private slots — each thread gets its own.
 *
 * Usage:
 *   Log.push_context ("42:textDocument/hover");
 *   Log.debug ("hover", "resolved symbol at %d:%d", line, col);
 *   Log.pop_context ();
 */
namespace Vls.Log {
    private static GLib.Private _thread_name;
    private static GLib.Private _stack_index;
    private static GLib.GenericArray<GLib.Queue<NdcEntry>> _all_stacks;
    private static int _trace = 2;  // 0=OFF, 1=MESSAGES, 2=VERBOSE
    private static LogLevelFlags _min_level = LogLevelFlags.LEVEL_DEBUG;

    private const int MAX_NDC_DEPTH = 8;

    private class NdcEntry {
        public string context;
        public GLib.Timer? timer;

        public NdcEntry (string ctx, owned GLib.Timer? t) {
            context = ctx;
            timer = (owned) t;
        }
    }

    /**
     * Initialize the logging subsystem. Call once from main() before any
     * other Log calls. Sets the calling thread's name to "main".
     */
    public static void init () {
        _thread_name = new GLib.Private (null);
        _stack_index = new GLib.Private (null);
        _all_stacks = new GLib.GenericArray<GLib.Queue<NdcEntry>> ();
        // Create main thread's stack (index 0)
        _all_stacks.add (new GLib.Queue<NdcEntry> ());
        _stack_index.set ((void*) 0);
        set_thread_name ("main");
    }

    /**
     * Set the minimum log level. Messages below this level are short-circuited
     * before format string evaluation.
     */
    public static void set_min_level (LogLevelFlags level) {
        _min_level = level;
    }

    /**
     * Update the trace level (called by the $/setTrace handler).
     * 0 = OFF, 1 = MESSAGES, 2 = VERBOSE (matches Lsp.TraceValue ordinal).
     */
    public static void set_trace (int trace) {
        _trace = trace;
    }

    // --- Thread name ---

    public static void set_thread_name (string name) {
        _thread_name.set ((void*) name);
    }

    public static string get_thread_name () {
        return (string) _thread_name.get () ?? "unknown";
    }

    // --- NDC push/pop ---

    /**
     * Push a context string onto the per-thread NDC stack.
     * In debug builds, asserts if depth exceeds MAX_NDC_DEPTH (leak detection).
     */
    public static void push_context (string context) {
        unowned var stack = get_or_create_stack ();
        stack.push_head (new NdcEntry (context, null));
#if DEBUG
        assert (stack.length <= MAX_NDC_DEPTH);
#endif
    }

    /**
     * Push a timed context. When popped, logs "<context> completed in Xms".
     */
    public static void push_timer (string context) {
        unowned var stack = get_or_create_stack ();
        stack.push_head (new NdcEntry (context, new GLib.Timer ()));
#if DEBUG
        assert (stack.length <= MAX_NDC_DEPTH);
#endif
    }

    /**
     * Pop the top entry from the NDC stack. If the entry was created with
     * push_timer(), logs the elapsed time.
     */
    public static void pop_context () {
        unowned var stack = get_or_create_stack ();
        if (stack.length == 0) {
            warning ("Vls.Log.pop_context: stack underflow");
            return;
        }
        var entry = stack.peek_head ();
        if (entry.timer != null) {
            double elapsed = entry.timer.elapsed ();
            string ctx = get_context ();
            GLib.stderr.printf ("%s [%s] [%s] %s: completed in %.3fs\n",
                format_timestamp (), get_thread_name (), ctx,
                entry.context, elapsed);
        }
        stack.pop_head ();
    }

    /**
     * Return the full NDC stack as "outer > inner" string.
     */
    public static string get_context () {
        unowned var stack = get_or_create_stack ();
        if (stack.length == 0)
            return "";

        var sb = new StringBuilder ();
        for (uint i = 0; i < stack.length; i++) {
            if (i > 0)
                sb.append (" > ");
            sb.append (stack.peek_nth (i).context);
        }
        return sb.str;
    }

    // --- Log methods ---

    public static void debug (string? domain, string format, ...) {
        if (!check_level (LogLevelFlags.LEVEL_DEBUG)) return;
        va_list args = va_list ();
        string msg = format.vprintf (args);
        log_full (domain, LogLevelFlags.LEVEL_DEBUG, msg);
    }

    public static void info (string? domain, string format, ...) {
        if (!check_level (LogLevelFlags.LEVEL_INFO)) return;
        va_list args = va_list ();
        string msg = format.vprintf (args);
        log_full (domain, LogLevelFlags.LEVEL_INFO, msg);
    }

    public static void message (string? domain, string format, ...) {
        if (!check_level (LogLevelFlags.LEVEL_MESSAGE)) return;
        va_list args = va_list ();
        string msg = format.vprintf (args);
        log_full (domain, LogLevelFlags.LEVEL_MESSAGE, msg);
    }

    public static void warn (string? domain, string format, ...) {
        if (!check_level (LogLevelFlags.LEVEL_WARNING)) return;
        va_list args = va_list ();
        string msg = format.vprintf (args);
        log_full (domain, LogLevelFlags.LEVEL_WARNING, msg);
    }

    public static void error (string? domain, string format, ...) {
        if (!check_level (LogLevelFlags.LEVEL_CRITICAL)) return;
        va_list args = va_list ();
        string msg = format.vprintf (args);
        log_full (domain, LogLevelFlags.LEVEL_CRITICAL, msg);
    }

    // --- Internal ---

    private static bool check_level (LogLevelFlags level) {
        if (level < _min_level)
            return false;
        switch (_trace) {
            case 0:  // OFF
                if (level == LogLevelFlags.LEVEL_DEBUG ||
                    level == LogLevelFlags.LEVEL_INFO ||
                    level == LogLevelFlags.LEVEL_MESSAGE)
                    return false;
                break;
            case 1:  // MESSAGES
                if (level == LogLevelFlags.LEVEL_DEBUG)
                    return false;
                break;
            case 2:  // VERBOSE
                break;
        }
        return true;
    }

    private static void log_full (string? domain, LogLevelFlags level, string message) {
        string thread = get_thread_name ();
        string ndc = get_context ();
        string ts = format_timestamp ();
        string dom = (domain != null && domain != "") ? domain + ": " : "";

        GLib.stderr.printf ("%s [%s] [%s] %s%s\n", ts, thread, ndc, dom, message);
    }

    private static string format_timestamp () {
        return new GLib.DateTime.now_local ().format ("%Y-%m-%d %H:%M:%S.%3f");
    }

    private static unowned GLib.Queue<NdcEntry> get_or_create_stack () {
        void* idx_ptr = _stack_index.get ();
        if (idx_ptr != null) {
            int idx = (int) ((long) idx_ptr);
            return _all_stacks[idx];
        }
        // New thread — create stack and register
        var stack = new GLib.Queue<NdcEntry> ();
        _all_stacks.add ((owned) stack);
        int new_idx = (int) (_all_stacks.length - 1);
        _stack_index.set ((void*) ((long) new_idx));
        return _all_stacks[new_idx];
    }
}
