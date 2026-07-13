/* integration.vala
 *
 * Integration test: drives a running vala-language-server over JSON-RPC and
 * asserts that opening a Vala file with an error produces diagnostics.
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
 * along with this program.  If not see <http://www.gnu.org/licenses/>.
 */

using GLib;
using Jsonrpc;

const string FIXTURE = """public void main () {
    undefined_function ();
}
""";

class Helpers {
    public Variant build_dict (...) {
        var builder = new VariantBuilder (VariantType.VARDICT);
        var l = va_list ();
        while (true) {
            string? key = l.arg ();
            if (key == null)
                break;
            Variant val = l.arg ();
            builder.add ("{sv}", key, val);
        }
        return builder.end ();
    }

    public static Variant empty_dict () {
        return new VariantBuilder (VariantType.VARDICT).end ();
    }

    public static Variant? sync_call (Jsonrpc.Client client, string method, Variant? @params) {
        Variant? result = null;
        try {
            client.call (method, @params, null, out result);
        } catch (Error e) {
            return null;
        }
        return result;
    }

    public static void notify (Jsonrpc.Client client, string method, Variant? @params) {
        try {
            client.send_notification (method, @params);
        } catch (Error e) {}
    }
}

const string SYMBOL_FIXTURE = """public class Foo {
    public int bar () {
        return 0;
    }
}
""";

const string COMPLETION_FIXTURE = """public class Foo {
    public int bar () { return 0; }
    public void baz () {
        Foo f = new Foo ();
        f.
    }
}
""";

const string FORMAT_FIXTURE = """public class Foo {
public int bar () {
return 0;
}
}
""";

class TestSession {
    public Jsonrpc.Client client;
    public Subprocess server;
    public string uri;
    public File root;
}

// Spawn a server, initialize it against a temp root, open `fixture` as a Vala
// document, and wait until analysis has run (signalled by the first
// publishDiagnostics notification) before returning.
TestSession setup_session (string fixture) {
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var root = File.new_for_path (Path.build_filename (
        Environment.get_tmp_dir (), "vls-sess-" + Random.int_range (0, int.MAX).to_string ()));
    try {
        root.make_directory_with_parents ();
    } catch (Error e) {
        assert_not_reached ();
    }
    var fixture_file = root.get_child ("sample.vala");
    try {
        FileUtils.set_contents (fixture_file.get_path (), fixture);
    } catch (Error e) {
        assert_not_reached ();
    }
    string uri = fixture_file.get_uri ();

    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
    Subprocess server;
    try {
        server = launcher.spawnv ({ server_path });
    } catch (Error e) {
        assert_not_reached ();
    }
    var stream = new SimpleIOStream (server.get_stdout_pipe (), server.get_stdin_pipe ());
    var client = new Jsonrpc.Client (stream);
    var h = new Helpers ();

    Variant? init_result = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string (root.get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result != null);
    Helpers.notify (client, "initialized", Helpers.empty_dict ());

    // Wait until analysis has run before issuing semantic requests.
    var loop = new MainLoop ();
    client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    Helpers.notify (client, "textDocument/didOpen", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (uri),
            languageId: new Variant.string ("vala"),
            version: new Variant.int32 (1),
            text: new Variant.string (fixture)
        )
    ));
    var timeout_id = Timeout.add (8000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    var s = new TestSession ();
    s.client = client;
    s.server = server;
    s.uri = uri;
    s.root = root;
    return s;
}

void teardown_session (TestSession s) {
    Helpers.notify (s.client, "exit", Helpers.empty_dict ());
    s.server.force_exit ();
    try {
        s.root.get_child ("sample.vala").@delete ();
        s.root.@delete ();
    } catch (Error e) {}
}

void test_publish_diagnostics () {
    // Locate the server binary (set by meson, with a sensible fallback).
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    // Prepare a fixture file inside a temp root directory.
    var root = File.new_for_path (Path.build_filename (
        Environment.get_tmp_dir (), "vls-integration-" + Random.int_range (0, int.MAX).to_string ()));
    try {
        root.make_directory_with_parents ();
    } catch (Error e) {
        assert_not_reached ();
    }
    var fixture = root.get_child ("sample.vala");
    try {
        FileUtils.set_contents (fixture.get_path (), FIXTURE);
    } catch (Error e) {
        assert_not_reached ();
    }
    string uri = fixture.get_uri ();

    // Spawn the server and connect to its stdio as a JSON-RPC client.
    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
    Subprocess server;
    try {
        server = launcher.spawnv ({ server_path });
    } catch (Error e) {
        assert_not_reached ();
    }
    var stream = new SimpleIOStream (server.get_stdout_pipe (), server.get_stdin_pipe ());
    var client = new Jsonrpc.Client (stream);
    var h = new Helpers ();

    // initialize
    Variant? init_result = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string (root.get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result != null);

    // notify "initialized"
    Helpers.notify (client, "initialized", Helpers.empty_dict ());

    // Capture textDocument/publishDiagnostics notifications.
    Variant? diag_params = null;
    var loop = new MainLoop ();
    client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics") {
            Variant? diags = @params.lookup_value ("diagnostics", VariantType.ARRAY);
            // The server may publish an empty notification before analysis
            // finishes; wait for the populated one.
            if (diags != null && diags.n_children () > 0) {
                diag_params = @params;
                loop.quit ();
            }
        }
    });

    // Open the fixture (Vala file with an error).
    Helpers.notify (client, "textDocument/didOpen", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (uri),
            languageId: new Variant.string ("vala"),
            version: new Variant.int32 (1),
            text: new Variant.string (FIXTURE)
        )
    ));

    // Wait for the diagnostics notification (with a timeout).
    var timeout_id = Timeout.add (8000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    // Shut the server down.
    Helpers.notify (client, "exit", Helpers.empty_dict ());
    server.force_exit ();

    // Assert we received at least one diagnostic.
    assert (diag_params != null);
    Variant? diagnostics = diag_params.lookup_value ("diagnostics", VariantType.ARRAY);
    assert (diagnostics != null);
    assert (diagnostics.n_children () > 0);

    // Clean up the temp directory.
    try {
        fixture.@delete ();
        root.@delete ();
    } catch (Error e) {}
}

void test_non_native_root_survives () {
    // A non-native root URI (e.g. an http:// URL) previously aborted the
    // whole server via GLib.error (). It must instead reply with an error and
    // keep running.
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
    Subprocess server;
    try {
        server = launcher.spawnv ({ server_path });
    } catch (Error e) {
        assert_not_reached ();
    }
    var stream = new SimpleIOStream (server.get_stdout_pipe (), server.get_stdin_pipe ());
    var client = new Jsonrpc.Client (stream);
    var h = new Helpers ();

    // initialize with a non-native root URI must not crash the server.
    Variant? init_result = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string ("http://example.com/"),
        capabilities: Helpers.empty_dict ()
    ));
    // The server replies with an error (sync_call returns null), not abort.
    assert (init_result == null);

    // The server must still be alive: a subsequent, valid initialize must
    // succeed. If it had aborted on the non-native initialize, the JSON-RPC
    // connection would be dead and this call would fail (or hang).
    var root = File.new_for_path (Path.build_filename (
        Environment.get_tmp_dir (), "vls-nonnative-" + Random.int_range (0, int.MAX).to_string ()));
    try {
        root.make_directory_with_parents ();
    } catch (Error e) {
        assert_not_reached ();
    }
    Variant? init_result2 = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string (root.get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result2 != null);
    try {
        root.@delete ();
    } catch (Error e) {}

    Helpers.notify (client, "exit", Helpers.empty_dict ());
    server.force_exit ();
}

void test_initialize_capabilities () {
    // initialize must advertise the capability set the server provides today.
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
    Subprocess server;
    try {
        server = launcher.spawnv ({ server_path });
    } catch (Error e) {
        assert_not_reached ();
    }
    var stream = new SimpleIOStream (server.get_stdout_pipe (), server.get_stdin_pipe ());
    var client = new Jsonrpc.Client (stream);
    var h = new Helpers ();

    Variant? init_result = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string (File.new_for_path (Environment.get_tmp_dir ()).get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result != null);
    Variant? capabilities = init_result.lookup_value ("capabilities", VariantType.VARDICT);
    assert (capabilities != null);
    assert (capabilities.lookup_value ("completionProvider", null) != null);
    assert (capabilities.lookup_value ("definitionProvider", null) != null);
    assert (capabilities.lookup_value ("documentSymbolProvider", null) != null);

    Helpers.notify (client, "exit", Helpers.empty_dict ());
    server.force_exit ();
}

void test_document_symbol () {
    // A file with a class and method must yield a non-empty symbol outline.
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/documentSymbol", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    assert (res.is_of_type (VariantType.ARRAY));
    assert (res.n_children () > 0);
    teardown_session (s);
}



void test_hover () {
    // Hovering over the class name must return a result with contents.
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/hover", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (0), character: new Variant.int32 (14))
    ));
    assert (res != null);
    assert (res.lookup_value ("contents", null) != null);
    teardown_session (s);
}

void test_goto_definition () {
    // Requesting the definition of a method must return a non-null location.
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/definition", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    // goto_definition returns a single Location or an array of Locations.
    if (res.is_of_type (VariantType.ARRAY)) {
        assert (res.n_children () > 0);
    } else {
        assert (res.lookup_value ("uri", null) != null);
        assert (res.lookup_value ("range", null) != null);
    }
    teardown_session (s);
}

void test_range_formatting () {
    // The format handler shells out to uncrustify; skip gracefully when it is
    // not installed so the suite stays green in environments without it.
    if (Environment.find_program_in_path ("uncrustify") == null) {
        Test.skip ();
        return;
    }
    // A badly-indented file must yield at least one TextEdit covering the document.
    var s = setup_session (FORMAT_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/rangeFormatting", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        range: h.build_dict (
            start: h.build_dict (line: new Variant.int32 (0), character: new Variant.int32 (0)),
            end: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (1))
        ),
        options: h.build_dict (tabSize: new Variant.int32 (4), insertSpaces: new Variant.boolean (true))
    ));
    assert (res != null);
    assert (res.is_of_type (VariantType.ARRAY));
    assert (res.n_children () > 0);
    // Json.gvariant_deserialize wraps each edit in a variant; unwrap it.
    Variant first = res.get_child_value (0);
    if (first.is_of_type (VariantType.VARIANT))
        first = first.get_variant ();
    assert (first.is_of_type (VariantType.VARDICT));
    assert (first.lookup_value ("range", null) != null);
    assert (first.lookup_value ("newText", null) != null);
    teardown_session (s);
}

void test_completion () {
    // Completion after a member access must return at least one item.
    var s = setup_session (COMPLETION_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/completion", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (10))
    ));
    assert (res != null);
    assert (res.is_of_type (VariantType.ARRAY));
    assert (res.n_children () > 0);
    teardown_session (s);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/vls/integration/publish_diagnostics", test_publish_diagnostics);
    Test.add_func ("/vls/integration/non_native_root_survives", test_non_native_root_survives);
    Test.add_func ("/vls/integration/initialize_capabilities", test_initialize_capabilities);
    Test.add_func ("/vls/integration/document_symbol", test_document_symbol);
    Test.add_func ("/vls/integration/hover", test_hover);
    Test.add_func ("/vls/integration/goto_definition", test_goto_definition);
    Test.add_func ("/vls/integration/range_formatting", test_range_formatting);
    Test.add_func ("/vls/integration/completion", test_completion);
    return Test.run ();
}
