/* int_golden.vala
 *
 * Golden integration tests: a fixture + an expected JSON reply, compared with
 * Helpers.assert_json_equals. One subdirectory under test/golden/ per feature.
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

using GLib;
using Jsonrpc;

// Locate <repo>/test/golden by walking up until a directory that
// actually contains test/golden is found (the build dir also has a
// generated src/ subtree, so we key on test/golden itself).
string golden_dir () {
    var d = Environment.get_current_dir ();
    for (int i = 0; i < 6; i++) {
        var cand = GLib.Path.build_filename (d, "test", "golden");
        if (FileUtils.test (cand, FileTest.IS_DIR))
            return cand;
        string parent = GLib.Path.get_dirname (d);
        if (parent == d)
            break;
        d = parent;
    }
    return GLib.Path.build_filename (Environment.get_current_dir (), "test", "golden");
}

void test_golden_document_symbol () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/documentSymbol", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "document_symbol", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_goto_definition () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/definition", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "goto_definition", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}
