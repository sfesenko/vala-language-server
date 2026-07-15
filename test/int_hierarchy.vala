/* int_hierarchy.vala
 *
 * Call/type hierarchy integration tests.
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

void test_implementation () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/implementation", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (25))
    ));
    if (res != null) {
        if (res.is_of_type (VariantType.ARRAY)) {
            assert (res.n_children () > 0);
        } else {
            assert (res.lookup_value ("uri", null) != null);
        }
    }
    teardown_session (s);
}
