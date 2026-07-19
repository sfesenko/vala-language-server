/* int_regression.vala
 *
 * Adversarial smoke tests: feed fixtures that have historically crashed
 * the server (template-string interpolations, single-dollar interpolation,
 * inverted source references) to every handler and assert the server does
 * not crash — it must return a well-formed reply (possibly empty), never
 * abort. This is the safety net every feature migration runs behind.
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

const string REG_TEMPLATE_STRING_FIXTURE = """public class Foo {
    public string build (string a, string b) {
        return @"$(a)-$(b)";
    }
}
""";

const string REG_SINGLE_DOLLAR_FIXTURE = """public class Foo {
    public void m () {
        var x = $marker;
    }
}
""";

// A fixture whose analyzed AST can yield inverted source references
// (end before begin), the second historical crash class.
const string REG_INVERTED_REF_FIXTURE = """public class Foo {
    public int bar () {
        return 0;
    }
    public void baz () {
        var x = bar ();
        var y = this.bar ();
    }
}
""";

// Build minimally-valid params for [method] so the server can attempt to
// handle it. Malformed/invalid params are fine (they yield an error reply,
// not a crash); the point is the server must stay alive.
Variant build_smoke_params (TestSession s, string method, Helpers h) {
    var dict = h.build_dict (textDocument: h.build_dict (uri: new Variant.string (s.uri)));
    if (method.has_prefix ("textDocument/") && method != "textDocument/formatting"
        && method != "textDocument/rangeFormatting") {
        dict = h.build_dict (
            textDocument: h.build_dict (uri: new Variant.string (s.uri)),
            position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (1))
        );
    }
    if (method == "textDocument/rangeFormatting" || method == "textDocument/semanticTokens/range"
        || method == "textDocument/inlayHint") {
        dict = h.build_dict (
            textDocument: h.build_dict (uri: new Variant.string (s.uri)),
            range: h.build_dict (
                start: h.build_dict (line: new Variant.int32 (0), character: new Variant.int32 (0)),
                end: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (1)))
        );
    }
    if (method == "textDocument/rename") {
        dict = h.build_dict (
            textDocument: h.build_dict (uri: new Variant.string (s.uri)),
            position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (1)),
            newName: new Variant.string ("renamed")
        );
    }
    if (method == "workspace/symbol") {
        dict = h.build_dict (query: new Variant.string (""));
    }
    return dict;
}

void smoke_fixture (string fixture) {
    // Every request method the server handles.
    string[] methods = {
        "textDocument/documentSymbol",
        "textDocument/hover",
        "textDocument/definition",
        "textDocument/references",
        "textDocument/documentHighlight",
        "textDocument/implementation",
        "textDocument/prepareRename",
        "textDocument/rename",
        "textDocument/inlayHint",
        "textDocument/codeLens",
        "textDocument/completion",
        "textDocument/signatureHelp",
        "textDocument/semanticTokens/full",
        "textDocument/semanticTokens/range",
        "textDocument/formatting",
        "textDocument/rangeFormatting",
        "workspace/symbol",
        "textDocument/typeHierarchy/prepare",
        "textDocument/callHierarchy/incomingCalls",
    };

    var s = setup_session (fixture);
    var h = new Helpers ();
    bool crashed = false;
    foreach (var method in methods) {
        // A method-level error reply (invalid params, etc.) is fine; only a
        // transport failure (broken pipe) means the server died on this input.
        try {
            Variant? r;
            s.client.call (method, build_smoke_params (s, method, h), null, out r);
        } catch (IOError e) {
            crashed = true;
        } catch (Error e) {
        }
    }
    assert (!crashed);
    teardown_session (s);
}

void test_adversarial_smoke_template_string () {
    smoke_fixture (REG_TEMPLATE_STRING_FIXTURE);
}

void test_adversarial_smoke_single_dollar () {
    smoke_fixture (REG_SINGLE_DOLLAR_FIXTURE);
}

void test_adversarial_smoke_inverted_ref () {
    smoke_fixture (REG_INVERTED_REF_FIXTURE);
}
