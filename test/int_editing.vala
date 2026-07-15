/* int_editing.vala
 *
 * Editing integration tests: completion, formatting.
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

void test_range_formatting () {
    if (Environment.find_program_in_path ("uncrustify") == null) {
        Test.skip ();
        return;
    }
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
    Variant first = res.get_child_value (0);
    if (first.is_of_type (VariantType.VARIANT))
        first = first.get_variant ();
    assert (first.is_of_type (VariantType.VARDICT));
    assert (first.lookup_value ("range", null) != null);
    assert (first.lookup_value ("newText", null) != null);
    teardown_session (s);
}

void test_completion () {
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
