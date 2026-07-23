/* int_navigation.vala
 *
 * Navigation integration tests: document symbol, hover, goto definition.
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

void test_document_symbol () {
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
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/definition", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    if (res.is_of_type (VariantType.ARRAY)) {
        assert (res.n_children () > 0);
    } else {
        assert (res.lookup_value ("uri", null) != null);
        assert (res.lookup_value ("range", null) != null);
    }
    teardown_session (s);
}

string? hover_value_at (TestSession s, Helpers h, int line, int character) {
    Variant? res = Helpers.sync_call (s.client, "textDocument/hover", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (line), character: new Variant.int32 (character))
    ));
    // Server replies NULL with `Variant.maybe(VARIANT, null)` — type string
    // "mv" — not a null pointer. Treat both as "no hover".
    if (res == null || res.get_type_string () == "mv")
        return null;
    var contents = res.lookup_value ("contents", null);
    if (contents == null)
        return null;
    // Drill into the MarkedString array (legacy) or MarkupContent (new).
    // Both serialize cleanly — pick the language=vala piece's value.
    Json.Node node = Json.gvariant_serialize (contents);
    if (node.get_node_type () == Json.NodeType.ARRAY) {
        var arr = node.get_array ();
        uint n = arr.get_length ();
        for (uint i = 0; i < n; i++) {
            var elem = arr.get_element (i);
            if (elem.get_node_type () != Json.NodeType.OBJECT)
                continue;
            var obj = elem.get_object ();
            string val = obj.get_string_member_with_default ("value", "");
            if (val.length > 0)
                return val;
        }
        return null;
    }
    if (node.get_node_type () == Json.NodeType.OBJECT) {
        string val = node.get_object ().get_string_member_with_default ("value", "");
        return val.length > 0 ? val : null;
    }
    return null;
}

Variant? definition_at (TestSession s, Helpers h, int line, int character) {
    Variant? res = Helpers.sync_call (s.client, "textDocument/definition", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (line), character: new Variant.int32 (character))
    ));
    if (res == null || res.get_type_string () == "mv")
        return null;
    return res;
}

// "hello name world" — line 2 of PLAIN_STRING_FIXTURE
//   8 spaces | string *str* | greeting | = | "hello name world";
//   `name` symbol is at character 33.
void test_hover_inside_plain_string_is_null () {
    var s = setup_session (PLAIN_STRING_FIXTURE);
    var h = new Helpers ();
    string? v = hover_value_at (s, h, 2, 33);
    assert (v == null);
    teardown_session (s);
}

void test_definition_inside_plain_string_is_null () {
    var s = setup_session (PLAIN_STRING_FIXTURE);
    var h = new Helpers ();
    Variant? res = definition_at (s, h, 2, 33);
    // Either null or an empty array
    assert (res == null || (res.is_of_type (VariantType.ARRAY) && res.n_children () == 0));
    teardown_session (s);
}

// INTERP_TYPING_FIXTURE: `string s = @"abc $x $(y) def";` on line 2
// positions:
//   $x : x at character 26   (int x — declared in method params)
//   $(y): y at character 30  (string y — declared in method params)
void test_hover_inside_interp_shows_var_type () {
    var s = setup_session (INTERP_TYPING_FIXTURE);
    var h = new Helpers ();
    string? x_hover = hover_value_at (s, h, 2, 26);
    assert (x_hover != null);
    // x is an int local/param — must NOT show as "string"
    assert ("int" in x_hover);
    assert (!("string" in x_hover.down ()));

    string? y_hover = hover_value_at (s, h, 2, 30);
    assert (y_hover != null);
    assert ("string" in y_hover);
    teardown_session (s);
}

void test_definition_inside_interp_jumps_to_param () {
    var s = setup_session (INTERP_TYPING_FIXTURE);
    var h = new Helpers ();
    Variant? res = definition_at (s, h, 2, 26);
    assert (res != null);

    Variant location;
    if (res.is_of_type (VariantType.VARDICT)) {
        location = res;
    } else if (res.is_of_type (VariantType.ARRAY)) {
        assert (res.n_children () > 0);
        location = res.get_child_value (0);
    } else {
        location = res;
    }
    var range = location.lookup_value ("range", null);
    var start = range.lookup_value ("start", null);
    int line = (int) start.lookup_value ("line", null).get_int64 ();
    // The parameter `int x` is declared on line 1
    assert (line == 1);
    teardown_session (s);
}

// Editing the body of an interpolated string @"... $x $(y) ..." repeatedly
// used to segfault the server (combinations of find_real_symbol on null
// symbol and SymbolEnumerator-on-null iterating). Drive several edit cycles
// and exercise the most sensitive handlers (hover, definition, documentSymbol,
// semanticTokens/full) after each cycle to flush out lingering state.
void test_edit_interp_string_no_crash () {
    var s = setup_session (INTERP_TYPING_FIXTURE);
    var h = new Helpers ();

    string[] edits = {
        """public class Foo {
    public void build (int x, string y) {
        string s = @"abc $x $(y) def $x again";
    }
}
""",
        """public class Foo {
    public void build (int x, string y) {
        string s = @"abc $x $(y) def $(x)";
    }
}
""",
        """public class Foo {
    public void build (int x, string y) {
        string s = @"$x $x $(y) $(y) $(x)";
    }
}
""",
        INTERP_TYPING_FIXTURE
    };

    int version = 2;
    foreach (var text in edits) {
        var loop = new MainLoop ();
        s.client.notification.connect ((c, method, @params) => {
            if (method == "textDocument/publishDiagnostics") {
                // Only quit on diagnostics for our file
                var uri_val = @params.lookup_value ("uri", VariantType.STRING);
                if (uri_val != null && (string) uri_val == s.uri)
                    loop.quit ();
            }
        });
        var timeout_id = Timeout.add (15000, () => { loop.quit (); return false; });

        Helpers.notify (s.client, "textDocument/didChange", h.build_dict (
            textDocument: h.build_dict (
                uri: new Variant.string (s.uri),
                version: new Variant.int32 (version)
            ),
            contentChanges: new Variant.array (null, { h.build_dict (text: new Variant.string (text)) })
        ));
        loop.run ();
        Source.remove (timeout_id);

        // Locate $x in this snippet for the hover/definition probes.
        long x_pos = -1;
        long line_idx = -1;
        long cur_line = 0;
        long cur_col = 0;
        for (long i = 0; i < text.length; i++) {
            if (text[i] == '\n') {
                cur_line++;
                cur_col = 0;
                continue;
            }
            if (text[i] == '$' && i + 1 < text.length && text[i+1] == 'x') {
                x_pos = cur_col + 1; // position over `x` in `$x`
                line_idx = cur_line;
                break;
            }
            cur_col++;
        }
        assert (x_pos >= 0);

        // hover inside $x: must return ``int x``, not ``string``
        string? hover = hover_value_at (s, h, (int) line_idx, (int) x_pos);
        assert (hover != null);
        assert ("int" in hover);
        assert (!("string" in hover.down ()));

        // definition at $x: must jump to the parameter declaration
        Variant? def = definition_at (s, h, (int) line_idx, (int) x_pos);
        assert (def != null);

        // documentSymbol: must not crash on the resulting AST
        Variant? ds = Helpers.sync_call (s.client, "textDocument/documentSymbol", h.build_dict (
            textDocument: h.build_dict (uri: new Variant.string (s.uri))
        ));
        assert (ds != null);

        // semanticTokens/full: must not crash on the resulting AST
        Variant? st = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
            textDocument: h.build_dict (uri: new Variant.string (s.uri))
        ));
        assert (st != null);

        version++;
    }

    teardown_session (s);
}
