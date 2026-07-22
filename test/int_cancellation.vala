/* int_cancellation.vala
 *
 * Integration tests for cancellation / rapid-edit stress.
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
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */

using GLib;
using Jsonrpc;

const string STRESS_FIXTURE = """public class Foo {
    public int bar () {
        return 42;
    }
}
""";

/**
 * Rapid-edit stress test: make many rapid edits without waiting for
 * recompilation between them. The server must survive and eventually
 * return valid results.
 *
 * This exercises:
 *   - cancellation (each edit cancels in-flight compiles)
 *   - Exponential backoff (update_context_delay_inc_us)
 *   - compile_in_progress_count guard
 *   - Idle safety net in wait_for_context_update
 */
void test_rapid_edits_recover () {
    var s = setup_session (STRESS_FIXTURE, "stress.vala");
    var h = new Helpers ();

    // Wait for initial diagnostics (first compile done).
    var loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    // Make 5 rapid edits — fire them in quick succession without waiting
    // for recompilation. Each edit cancels any in-flight compile.
    string[] versions = {
        "public class Foo {\n    public int bar () {\n        return 42;\n    }\n    public int baz () {\n        return 7;\n    }\n}\n",
        "public class Foo {\n    public int bar () {\n        return 0;\n    }\n    public int baz () {\n        return 7;\n    }\n}\n",
        "public class Foo {\n    public int bar () {\n        return 0;\n    }\n}\n",
        "public class Foo {\n    public int bar () {\n        return 42;\n    }\n    public void qux () {}\n}\n",
        STRESS_FIXTURE
    };

    for (int i = 0; i < versions.length; i++) {
        Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
            textDocument: h.build_dict (
                uri: new Variant.string (s.uri),
                version: new Variant.int32 (i + 2)
            ),
            contentChanges: new Variant.array (null, {
                h.build_dict (text: new Variant.string (versions[i]))
            })
        ));
        // Yield to main loop to let the server process the notification.
        // But don't wait for diagnostics.
        while (GLib.MainContext.default ().iteration (false));
    }

    // Wait for recompilation to complete by making a synchronous call.
    // sync_call blocks until the server responds, which triggers
    // wait_for_context_update internally.
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);

    // Verify completion still works after the edit storm.
    res = Helpers.sync_call (s.client, "textDocument/completion", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (2), character: new Variant.int32 (4))
    ));
    assert (res != null);

    teardown_session (s);
}

/**
 * Rapid cancel: verify that the server handles back-to-back
 * $/cancelRequest without crashing.
 */
void test_rapid_cancel () {
    var s = setup_session (STRESS_FIXTURE, "cancel_stress.vala");
    var h = new Helpers ();

    // Wait for initial compile.
    var loop = new MainLoop ();
    ulong handler_id = s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);
    assert (handler_id > 0);

    // Fire cancel requests — even though there's nothing to cancel,
    // the server should handle this gracefully.
    for (int i = 0; i < 10; i++) {
        Helpers.notify (s.client, "$/cancelRequest", h.build_dict (
            id: new Variant.int32 (i)
        ));
    }

    // Edit + cancel cycle.
    for (int i = 0; i < 5; i++) {
        string changed = STRESS_FIXTURE.replace (
            "return 42",
            @"return $(i * 10)"
        );
        Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
            textDocument: h.build_dict (
                uri: new Variant.string (s.uri),
                version: new Variant.int32 (i + 2)
            ),
            contentChanges: new Variant.array (null, {
                h.build_dict (text: new Variant.string (changed))
            })
        ));
        // Try to cancel requests that may be pending.
        for (int j = 0; j < 3; j++) {
            Helpers.notify (s.client, "$/cancelRequest", h.build_dict (
                id: new Variant.int32 (100 + i * 10 + j)
            ));
        }
    }

    // Wait for final diagnostics.
    loop = new MainLoop ();
    s.client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });
    // Trigger one more edit to guarantee recompilation.
    Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (s.uri),
            version: new Variant.int32 (20)
        ),
        contentChanges: new Variant.array (null, {
            h.build_dict (text: new Variant.string (STRESS_FIXTURE))
        })
    ));
    loop.run ();
    Source.remove (timeout_id);

    // Verify server still responds.
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);

    s.client.disconnect (handler_id);
    teardown_session (s);
}
