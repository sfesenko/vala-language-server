/* int_helpers.vala
 *
 * Shared helpers for VLS integration tests.
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

    /**
     * Assert that [actual] (an LSP reply Variant) equals the JSON stored at
     * [expected_path]. Both are serialized to canonical JSON text and compared.
     *
     * If the environment variable VLS_GOLDEN_RECORD is set to "1", the actual
     * reply is written to [expected_path] instead (creating parent directories),
     * which makes authoring golden fixtures a one-shot operation.
     */
    // Stabilize non-deterministic parts of a serialized reply: the session
    // temp directory carries a random id (vls-sess-<digits>), so two runs
    // never compare equal. Replace it with a fixed token.
    private static string normalize_golden (string s) {
        try {
            var re = new Regex ("vls-sess-[0-9]+");
            return re.replace (s, -1, 0, "vls-sess-0");
        } catch (Error e) {
            return s;
        }
    }

    public static void assert_json_equals (Variant actual, string expected_path) {
        var actual_node = Json.gvariant_serialize (actual);
        var actual_text = normalize_golden (Json.to_string (actual_node, false));

        if (Environment.get_variable ("VLS_GOLDEN_RECORD") == "1") {
            var dir = GLib.Path.get_dirname (expected_path);
            try {
                File.new_for_path (dir).make_directory_with_parents ();
            } catch (Error e) {}
            try {
                FileUtils.set_contents (expected_path, actual_text);
            } catch (Error e) {
                assert_not_reached ();
            }
            return;
        }

        string expected_text;
        try {
            FileUtils.get_contents (expected_path, out expected_text);
        } catch (Error e) {
            assert_not_reached ();
        }
        Json.Node expected_node;
        try {
            expected_node = Json.from_string (expected_text);
        } catch (Error e) {
            assert_not_reached ();
        }
        var expected_norm = normalize_golden (Json.to_string (expected_node, false));
        assert (actual_text == expected_norm);
    }
}

class TestSession {
    public Jsonrpc.Client client;
    public Subprocess server;
    public string uri;
    public File root;
    public string filename;
}

TestSession setup_session (string fixture, string? fixture_name = null) {
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
    if (fixture_name == null)
        fixture_name = "sample.vala";
    var fixture_file = root.get_child (fixture_name);
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
    s.filename = fixture_name;
    return s;
}

void teardown_session (TestSession s) {
    Helpers.notify (s.client, "exit", Helpers.empty_dict ());
    s.server.force_exit ();
    try {
        s.root.get_child (s.filename).@delete ();
        s.root.@delete ();
    } catch (Error e) {}
}

const string FIXTURE = """public void main () {
    undefined_function ();
}
""";

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

const string REFERENCES_FIXTURE = """public class Foo {
    public int bar () { return 0; }
    public void test () {
        var x = bar ();
        var y = this.bar ();
    }
}
""";

const string HIERARCHY_FIXTURE = """public abstract class Base {
    public abstract void do_it ();
}
public class Derived : Base {
    public override void do_it () { helper (); }
    public void caller () {
        do_it ();
        Base b = new Derived ();
    }
    void helper () {}
}
""";

const string TEMPLATE_STRING_FIXTURE = """public class Foo {
    public string build_name (string ns, string ver) {
        return @"$(ns)-$(ver)";
    }
}
""";

const string SIGNATURE_HELP_FIXTURE = """public class Foo {
    public int add (int a, int b) {
        return a + b;
    }
    public void use () {
        add (1, 2);
    }
}
""";

const string CODELENS_FIXTURE = """public abstract class Base {
    public abstract void do_it ();
}
public class Derived : Base {
    public override void do_it () {}
}
""";

const string CODEACTION_FIXTURE = """public enum Color {
    RED,
    GREEN,
    BLUE
}

public class Foo {
    public void bar (Color c) {
        int x = 5;
        switch (c) {
            case Color.RED:
                break;
        }
    }
}
""";

const string INLAY_HINT_FIXTURE = """public class Foo {
    public void run (string[] items) {
        var sum = items;
        foreach (var item in items) {
            var x = item;
        }
    }
}
""";
