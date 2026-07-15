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
