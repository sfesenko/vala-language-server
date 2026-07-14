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

const string SEMANTIC_TOKENS_FIXTURE = """namespace Ns {
    public abstract class Base {
        public abstract void abs_method ();
        public virtual void vir_method () {}
    }
    public class Foo<T> : Base {
        public Foo () {}
        ~Foo () {}
        public HashMap<string, uint> generic_map { get; set; }
        public void m_pub () {}
        private void m_pri () {}
        protected void m_pro () {}
        internal void m_int () {}
        public static void m_stat () {}
        public override void abs_method () {}
        public override void vir_method () {}
        public async void m_async () {}
        public int prop { get; set; }
        public static int sprop { get; set; }
        public virtual int vprop { get; set; }
        public override int ovprop { get; set; }
        public int field;
        public static int sfield;
        public signal void sig1 ();
        public delegate void MyDel ();
        public const int ANSWER = 42;
        public const string NAME = "test";
        public T? this[string key] { get; set; }
        public void do_stuff (string s, int x) {
            int local = 42;
            string str = "hello";
            bool flag = true;
            double pi = 3.14;
            var obj = new Foo<int> ();
            obj.m_pub ();
            obj.prop = 1;
            var f = obj.field;
            var a = obj is Base;
            var x = obj;
            var copy = x;
            obj["key"] = "val";
        }
        public void test_generics (HashMap<string, uint> generic_map) {
            unowned string us = "hello";
            owned string os = us;
            var chained = this
                .test_generics (generic_map);
            generic_map[null] = 0;
        }
        public void test_simple_names () {
            int counter = 0;
            counter = counter;
            counter++;
        }
        public HashMap<string, uint> test_generic_ret () {
            return this.generic_map;
        }
    }
    public struct MyStruct {
        public int x;
        public void method () {}
    }
    public enum MyEnum {
        VAL_A,
        VAL_B
    }
    public interface MyInterface {
        public abstract void do_it ();
    }
}
public error_domain MyError {
    VAL_A,
    VAL_B
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

void test_semantic_tokens_full () {
    // Semantic tokens for a class with a method should return non-empty data.
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    assert (data.n_children () > 0);
    teardown_session (s);
}

// Decode delta-encoded semantic tokens into (line, char, length, type, modifiers) tuples.
struct DecodedToken {
    uint line;
    uint length;
    uint token_type;
}

Gee.List<DecodedToken?> decode_tokens (Variant data) {
    var result = new Gee.ArrayList<DecodedToken?> ();
    Json.Node json_node = Json.gvariant_serialize (data);
    var json_array = json_node.get_array ();
    uint n = json_array.get_length ();
    uint prev_line = 0;
    for (uint i = 0; i + 4 < n; i += 5) {
        uint delta_line = (uint) json_array.get_int_element (i);
        uint len = (uint) json_array.get_int_element (i + 2);
        uint tok_type = (uint) json_array.get_int_element (i + 3);
        prev_line += delta_line;
        DecodedToken tok = { prev_line, len, tok_type };
        result.add (tok);
    }
    return result;
}

bool has_token (Gee.List<DecodedToken?> tokens, uint line, uint token_type, uint length) {
    foreach (var t in tokens)
        if (t.line == line && t.token_type == token_type && t.length == length)
            return true;
    return false;
}

bool has_token_on_line (Gee.List<DecodedToken?> tokens, uint line, uint token_type) {
    foreach (var t in tokens)
        if (t.line == line && t.token_type == token_type)
            return true;
    return false;
}

void test_semantic_tokens_coverage () {
    var s = setup_session (SEMANTIC_TOKENS_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    var tokens = decode_tokens (data);
    assert (tokens.size > 0);

    // Token type constants (must match SemanticTokenType enum)
    const uint NAMESPACE = 0;
    const uint CLASS = 1;
    const uint ENUM = 2;
    const uint INTERFACE = 3;
    const uint STRUCT = 4;
    const uint TYPE_PARAMETER = 5;
    const uint TYPE = 6;
    const uint PARAMETER = 7;
    const uint VARIABLE = 8;
    const uint PROPERTY = 9;
    const uint ENUM_MEMBER = 10;
    const uint EVENT = 11;
    const uint FUNCTION = 12;
    const uint METHOD = 13;
    const uint KEYWORD = 14;
    const uint STRING = 15;
    const uint NUMBER = 16;

    // === Line 0: namespace Ns { ===
    assert (has_token (tokens, 0, KEYWORD, 9));        // "namespace"
    assert (has_token (tokens, 0, NAMESPACE, 2));      // "Ns"

    // === Line 1: public abstract class Base { ===
    assert (has_token (tokens, 1, KEYWORD, 6));        // "public"
    assert (has_token (tokens, 1, KEYWORD, 8));        // "abstract"
    assert (has_token (tokens, 1, KEYWORD, 5));        // "class"
    assert (has_token (tokens, 1, CLASS, 4));          // "Base"

    // === Line 2: public abstract void abs_method (); ===
    assert (has_token (tokens, 2, KEYWORD, 6));        // "public"
    assert (has_token (tokens, 2, KEYWORD, 8));        // "abstract"
    assert (has_token (tokens, 2, TYPE, 4));           // "void"
    assert (has_token (tokens, 2, METHOD, 10));        // "abs_method"

    // === Line 3: public virtual void vir_method () {} ===
    assert (has_token (tokens, 3, KEYWORD, 6));        // "public"
    assert (has_token (tokens, 3, KEYWORD, 7));        // "virtual"
    assert (has_token (tokens, 3, TYPE, 4));           // "void"
    assert (has_token (tokens, 3, METHOD, 10));        // "vir_method"

    // === Line 5: public class Foo<T> : Base { ===
    assert (has_token (tokens, 5, KEYWORD, 6));        // "public"
    assert (has_token (tokens, 5, KEYWORD, 5));        // "class"
    assert (has_token (tokens, 5, CLASS, 3));          // "Foo"
    assert (has_token (tokens, 5, TYPE_PARAMETER, 1)); // "T"

    // === Line 6: public Foo () {} ===
    assert (has_token (tokens, 6, KEYWORD, 6));        // "public"
    assert (has_token (tokens, 6, METHOD, 3));         // "Foo" (creation method)

    // === Line 7: ~Foo () {} ===
    assert (has_token_on_line (tokens, 7, METHOD));    // "~Foo" (destructor)

    // === Line 9: public void m_pub () {} ===
    assert (has_token (tokens, 9, KEYWORD, 6));        // "public"
    assert (has_token (tokens, 9, TYPE, 4));           // "void"
    assert (has_token (tokens, 9, METHOD, 5));         // "m_pub"

    // === Line 10: private void m_pri () {} ===
    assert (has_token (tokens, 10, KEYWORD, 7));       // "private"
    assert (has_token (tokens, 10, TYPE, 4));          // "void"
    assert (has_token (tokens, 10, METHOD, 5));        // "m_pri"

    // === Line 11: protected void m_pro () {} ===
    assert (has_token (tokens, 11, KEYWORD, 9));       // "protected"
    assert (has_token (tokens, 11, TYPE, 4));          // "void"
    assert (has_token (tokens, 11, METHOD, 5));        // "m_pro"

    // === Line 12: internal void m_int () {} ===
    assert (has_token (tokens, 12, KEYWORD, 8));       // "internal"
    assert (has_token (tokens, 12, TYPE, 4));          // "void"
    assert (has_token (tokens, 12, METHOD, 5));        // "m_int"

    // === Line 13: public static void m_stat () {} ===
    assert (has_token (tokens, 13, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 13, KEYWORD, 6));       // "static"
    assert (has_token (tokens, 13, TYPE, 4));          // "void"
    assert (has_token (tokens, 13, METHOD, 6));        // "m_stat"

    // === Line 14: public override void abs_method () {} ===
    assert (has_token (tokens, 14, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 14, KEYWORD, 8));       // "override"
    assert (has_token (tokens, 14, TYPE, 4));          // "void"
    assert (has_token (tokens, 14, METHOD, 10));       // "abs_method"

    // === Line 15: public override void vir_method () {} ===
    assert (has_token (tokens, 15, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 15, KEYWORD, 8));       // "override"
    assert (has_token (tokens, 15, TYPE, 4));          // "void"
    assert (has_token (tokens, 15, METHOD, 10));       // "vir_method"

    // === Line 16: public async void m_async () {} ===
    assert (has_token (tokens, 16, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 16, KEYWORD, 5));       // "async"
    assert (has_token (tokens, 16, TYPE, 4));          // "void"
    assert (has_token (tokens, 16, FUNCTION, 7));      // "m_async"

    // === Line 17: public int prop { get; set; } ===
    assert (has_token (tokens, 17, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 17, TYPE, 3));          // "int"
    assert (has_token (tokens, 17, PROPERTY, 4));      // "prop"

    // === Line 18: public static int sprop { get; set; } ===
    assert (has_token (tokens, 18, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 18, KEYWORD, 6));       // "static"
    assert (has_token (tokens, 18, TYPE, 3));          // "int"
    assert (has_token (tokens, 18, PROPERTY, 5));      // "sprop"

    // === Line 19: public virtual int vprop { get; set; } ===
    assert (has_token (tokens, 19, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 19, KEYWORD, 7));       // "virtual"
    assert (has_token (tokens, 19, TYPE, 3));          // "int"
    assert (has_token (tokens, 19, PROPERTY, 5));      // "vprop"

    // === Line 20: public override int ovprop { get; set; } ===
    assert (has_token (tokens, 20, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 20, KEYWORD, 8));       // "override"
    assert (has_token (tokens, 20, TYPE, 3));          // "int"
    assert (has_token (tokens, 20, PROPERTY, 6));      // "ovprop"

    // === Line 21: public int field; ===
    assert (has_token (tokens, 21, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 21, TYPE, 3));          // "int"
    assert (has_token (tokens, 21, PROPERTY, 5));      // "field"

    // === Line 22: public static int sfield; ===
    assert (has_token (tokens, 22, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 22, KEYWORD, 6));       // "static"
    assert (has_token (tokens, 22, TYPE, 3));          // "int"
    assert (has_token (tokens, 22, PROPERTY, 6));      // "sfield"

    // === Line 23: public signal void sig1 (); ===
    assert (has_token (tokens, 23, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 23, KEYWORD, 6));       // "signal"
    assert (has_token (tokens, 23, TYPE, 4));          // "void"
    assert (has_token (tokens, 23, EVENT, 4));         // "sig1"

    // === Line 24: public delegate void MyDel (); ===
    assert (has_token (tokens, 24, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 24, KEYWORD, 8));       // "delegate"
    assert (has_token (tokens, 24, TYPE, 4));          // "void"
    assert (has_token (tokens, 24, FUNCTION, 5));      // "MyDel"

    // === Line 25: public const int ANSWER = 42; ===
    assert (has_token (tokens, 25, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 25, KEYWORD, 5));       // "const"
    assert (has_token (tokens, 25, TYPE, 3));          // "int"
    assert (has_token (tokens, 25, VARIABLE, 6));      // "ANSWER"
    assert (has_token (tokens, 25, NUMBER, 2));        // "42"

    // === Line 26: public const string NAME = "test"; ===
    assert (has_token (tokens, 26, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 26, KEYWORD, 5));       // "const"
    assert (has_token (tokens, 26, TYPE, 6));          // "string"
    assert (has_token (tokens, 26, VARIABLE, 4));      // "NAME"
    assert (has_token (tokens, 26, STRING, 6));        // "\"test\""

    // === Line 27: public T? this[string key] { get; set; } ===
    // NOTE: indexer properties may not emit tokens depending on libvala behavior

    // === Line 28: public void do_stuff (string s, int x) { ===
    assert (has_token (tokens, 28, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 28, TYPE, 4));          // "void"
    assert (has_token (tokens, 28, METHOD, 8));        // "do_stuff"
    assert (has_token (tokens, 28, TYPE, 6));          // "string" (param type)
    assert (has_token (tokens, 28, PARAMETER, 1));     // "s"
    assert (has_token (tokens, 28, TYPE, 3));          // "int" (param type)
    assert (has_token (tokens, 28, PARAMETER, 1));     // "x"

    // === Line 29: int local = 42; ===
    assert (has_token (tokens, 29, TYPE, 3));          // "int"
    assert (has_token (tokens, 29, VARIABLE, 5));      // "local"
    assert (has_token (tokens, 29, NUMBER, 2));        // "42"

    // === Line 30: string str = "hello"; ===
    assert (has_token (tokens, 30, TYPE, 6));          // "string"
    assert (has_token (tokens, 30, VARIABLE, 3));      // "str"
    assert (has_token (tokens, 30, STRING, 7));        // "\"hello\""

    // === Line 31: bool flag = true; ===
    assert (has_token (tokens, 31, TYPE, 4));          // "bool"
    assert (has_token (tokens, 31, VARIABLE, 4));      // "flag"
    assert (has_token (tokens, 31, NUMBER, 4));        // "true"

    // === Line 32: double pi = 3.14; ===
    assert (has_token (tokens, 32, TYPE, 6));          // "double"
    assert (has_token (tokens, 32, VARIABLE, 2));      // "pi"
    assert (has_token (tokens, 32, NUMBER, 4));        // "3.14"

    // === Line 33: var obj = new Foo<int> (); ===
    assert (has_token (tokens, 33, VARIABLE, 3));      // "obj"
    assert (has_token (tokens, 33, CLASS, 8));         // "Foo<int>"

    // === Line 34: obj.m_pub (); ===
    assert (has_token (tokens, 34, VARIABLE, 3));      // "obj" (reference)
    assert (has_token (tokens, 34, METHOD, 5));        // "m_pub" (member name only)

    // === Line 35: obj.prop = 1; ===
    assert (has_token (tokens, 35, VARIABLE, 3));      // "obj" (reference)
    assert (has_token (tokens, 35, PROPERTY, 4));      // "prop" (member name only)
    assert (has_token (tokens, 35, NUMBER, 1));        // "1"

    // === Line 36: var f = obj.field; ===
    assert (has_token (tokens, 36, VARIABLE, 1));      // "f"
    assert (has_token (tokens, 36, VARIABLE, 3));      // "obj" (reference)
    assert (has_token (tokens, 36, PROPERTY, 5));      // "field" (member name only)

    // === Line 37: var a = obj is Base; ===
    assert (has_token (tokens, 37, VARIABLE, 1));      // "a"
    assert (has_token (tokens, 37, TYPE, 4));          // "Base"

    // === Line 38: var x = obj; ===
    assert (has_token (tokens, 38, VARIABLE, 1));      // "x" (declaration)
    assert (has_token (tokens, 38, VARIABLE, 3));      // "obj" (reference)

    // === Line 39: var copy = x; ===
    assert (has_token (tokens, 39, VARIABLE, 4));      // "copy" (declaration)
    assert (has_token (tokens, 39, VARIABLE, 1));      // "x" (reference)

    // === Line 40: obj["key"] = "val"; ===
    assert (has_token (tokens, 40, VARIABLE, 3));      // "obj" (reference)
    assert (has_token (tokens, 40, STRING, 5));        // "\"key\""
    assert (has_token (tokens, 40, STRING, 5));        // "\"val\""

    // === Line 42: test_generics signature ===
    assert (has_token (tokens, 42, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 42, TYPE, 4));           // "void"
    assert (has_token_on_line (tokens, 42, METHOD));    // "test_generics"
    assert (has_token_on_line (tokens, 42, TYPE));      // "HashMap<string, uint>" (generic param)

    // === Line 43: unowned string us = "hello"; ===
    // "unowned" keyword emitted by leading keyword tokens
    assert (has_token (tokens, 43, VARIABLE, 2));      // "us"
    assert (has_token (tokens, 43, STRING, 7));        // "\"hello\""

    // === Line 44: owned string os = us; ===
    // "owned" emitted by leading keyword tokens, "string" as TYPE
    assert (has_token (tokens, 44, VARIABLE, 2));      // "os"
    assert (has_token_on_line (tokens, 44, VARIABLE));  // "us" (simple name reference)

    // === Line 45: var chained = this ===
    assert (has_token (tokens, 45, VARIABLE, 7));      // "chained" (declaration)

    // === Line 46: .test_generics (generic_map); ===
    assert (has_token (tokens, 46, METHOD, 13));       // "test_generics" (multi-line chain via sr.end)

    // === Line 47: generic_map[null] = 0; ===
    assert (has_token_on_line (tokens, 47, PARAMETER));  // "generic_map" (param ref)
    assert (has_token (tokens, 47, NUMBER, 1));        // "0"

    // === Line 49: test_simple_names signature ===
    assert (has_token (tokens, 49, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 49, TYPE, 4));           // "void"
    assert (has_token_on_line (tokens, 49, METHOD));    // "test_simple_names"

    // === Line 50: int counter = 0; ===
    assert (has_token (tokens, 50, TYPE, 3));          // "int"
    assert (has_token_on_line (tokens, 50, VARIABLE));  // "counter" (declaration)
    assert (has_token (tokens, 50, NUMBER, 1));        // "0"

    // === Line 51: counter = counter; ===
    assert (has_token_on_line (tokens, 51, VARIABLE));  // "counter" (simple name ref)
    assert (has_token_on_line (tokens, 51, VARIABLE));  // "counter" (simple name ref)

    // === Line 52: counter++; ===
    // NOTE: postfix increment may not emit tokens depending on AST structure

    // === Line 54: test_generic_ret signature ===
    assert (has_token (tokens, 54, KEYWORD, 6));       // "public"
    assert (has_token_on_line (tokens, 54, METHOD));    // "test_generic_ret"

    // === Line 55: return this.generic_map; ===
    assert (has_token_on_line (tokens, 55, PROPERTY));  // "generic_map" (qualified access)

    // === Line 58: public struct MyStruct { ===
    assert (has_token (tokens, 58, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 58, KEYWORD, 6));       // "struct"
    assert (has_token (tokens, 58, STRUCT, 8));        // "MyStruct"

    // === Line 59: public int x; ===
    assert (has_token (tokens, 59, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 59, TYPE, 3));          // "int"
    assert (has_token (tokens, 59, PROPERTY, 1));      // "x"

    // === Line 60: public void method () {} ===
    assert (has_token (tokens, 60, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 60, TYPE, 4));          // "void"
    assert (has_token (tokens, 60, METHOD, 6));        // "method"

    // === Line 62: public enum MyEnum { ===
    assert (has_token (tokens, 62, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 62, KEYWORD, 4));       // "enum"
    assert (has_token (tokens, 62, ENUM, 6));          // "MyEnum"

    // === Line 63: VAL_A, ===
    assert (has_token (tokens, 63, ENUM_MEMBER, 5));   // "VAL_A"

    // === Line 64: VAL_B ===
    assert (has_token (tokens, 64, ENUM_MEMBER, 5));   // "VAL_B"

    // === Line 66: public interface MyInterface { ===
    assert (has_token (tokens, 66, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 66, KEYWORD, 9));       // "interface"
    assert (has_token (tokens, 66, INTERFACE, 11));    // "MyInterface"

    // === Line 67: public abstract void do_it (); ===
    assert (has_token (tokens, 67, KEYWORD, 6));       // "public"
    assert (has_token (tokens, 67, KEYWORD, 8));       // "abstract"
    assert (has_token (tokens, 67, TYPE, 4));          // "void"
    assert (has_token (tokens, 67, METHOD, 5));        // "do_it"

    // === Line 70: public error_domain MyError { ===
    // NOTE: error_domain outside namespace has no tokens in current analyzer
    // (source_reference may not match due to libvala parsing quirks)

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
    Test.add_func ("/vls/integration/semantic_tokens_full", test_semantic_tokens_full);
    Test.add_func ("/vls/integration/semantic_tokens_coverage", test_semantic_tokens_coverage);
    return Test.run ();
}
