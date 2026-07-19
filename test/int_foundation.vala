/* int_foundation.vala
 *
 * Unit tests for VLS.Foundation position/range/buffer helpers.
 * Compiled against a minimal source set (util + TextDocument), since the
 * Foundation module is deliberately free of the LSP protocol layer. These
 * tests run in-process (no server subprocess) by calling the Foundation
 * functions directly.
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

using Vls.Foundation;
using Vala;

private Vala.SourceLocation loc (string fn, int line, int col) {
    return Vala.SourceLocation (fn, line, col);
}

void test_buffer_for () {
    var ctx = new Vala.CodeContext ();
    var sf = new Vala.SourceFile (ctx, Vala.SourceFileType.SOURCE, "test.vala", "hello\nworld");
    var buf = Vls.Foundation.buffer_for (sf);
    assert (buf != null);
    assert (buf == "hello\nworld");

    // null file -> null
    assert (Vls.Foundation.buffer_for (null) == null);
}

void test_slice_sourceref () {
    var ctx = new Vala.CodeContext ();
    var sf = new Vala.SourceFile (ctx, Vala.SourceFileType.SOURCE, "test.vala", "hello\nworld");
    // forward ref: line 1 col 1 ("h") to line 1 col 5 ("o") -> "hello"
    var sr = new Vala.SourceReference (sf, loc ("test.vala", 1, 1), loc ("test.vala", 1, 5));
    var slice = Vls.Foundation.slice_sourceref (sr);
    assert (slice == "hello");

    // inverted ref -> null
    var inv = new Vala.SourceReference (sf, loc ("test.vala", 1, 5), loc ("test.vala", 1, 1));
    assert (Vls.Foundation.slice_sourceref (inv) == null);

    // null sr -> null
    assert (Vls.Foundation.slice_sourceref (null) == null);
}

void test_normalize_sourceref () {
    var ctx = new Vala.CodeContext ();
    var sf = new Vala.SourceFile (ctx, Vala.SourceFileType.SOURCE, "test.vala", "line a\nline b\nline c");
    // inverted 153.33 - 153.27 -> 153.27 - 153.33
    var inv = new Vala.SourceReference (sf, loc ("test.vala", 153, 33), loc ("test.vala", 153, 27));
    var norm = Vls.Foundation.normalize_sourceref (inv);
    assert (norm.begin.line == 153);
    assert (norm.begin.column == 27);
    assert (norm.end.line == 153);
    assert (norm.end.column == 33);

    // negative/zero clamp -> (1,1)
    var neg = new Vala.SourceReference (sf, loc ("test.vala", -1, -2), loc ("test.vala", 0, 0));
    var n2 = Vls.Foundation.normalize_sourceref (neg);
    assert (n2.begin.line == 1 && n2.begin.column == 1);
    assert (n2.end.line == 1 && n2.end.column == 1);

    // null sr -> null
    assert (Vls.Foundation.normalize_sourceref (null) == null);
}

void test_position_from_sourceref () {
    var ctx = new Vala.CodeContext ();
    var sf = new Vala.SourceFile (ctx, Vala.SourceFileType.SOURCE, "test.vala", "abc");
    var sr = new Vala.SourceReference (sf, loc ("test.vala", 2, 4), loc ("test.vala", 2, 7));
    var p = Vls.Foundation.position_from_sourceref (sr);
    assert (p.line == 1);
    assert (p.character == 3); // column - 1

    // null -> (0,0)
    var pn = Vls.Foundation.position_from_sourceref (null);
    assert (pn.line == 0 && pn.character == 0);
}

void test_range_from_sourceref () {
    var ctx = new Vala.CodeContext ();
    var sf = new Vala.SourceFile (ctx, Vala.SourceFileType.SOURCE, "test.vala", "abc");
    var sr = new Vala.SourceReference (sf, loc ("test.vala", 2, 4), loc ("test.vala", 2, 7));
    var r = Vls.Foundation.range_from_sourceref (sr);
    // start = begin with column - 1
    assert (r.start.line == 1 && r.start.character == 3);
    // end = end.column (half-open exclusive)
    assert (r.end.line == 1 && r.end.character == 7);

    // a range derived from an inverted ref is never inverted (start <= end)
    var inv = new Vala.SourceReference (sf, loc ("test.vala", 5, 10), loc ("test.vala", 5, 4));
    var ri = Vls.Foundation.range_from_sourceref (inv);
    bool ordered = ri.start.line < ri.end.line ||
        (ri.start.line == ri.end.line && ri.start.character <= ri.end.character);
    assert (ordered);

    // null -> empty range
    var rn = Vls.Foundation.range_from_sourceref (null);
    assert (rn.start.line == 0 && rn.start.character == 0);
    assert (rn.end.line == 0 && rn.end.character == 0);
}

void test_offset_to_position () {
    var buf = "line0\nline1\nline2";
    // roundtrip with get_string_pos
    var p = Vls.Foundation.offset_to_position (buf, (long) Vls.Util.get_string_pos (buf, 1, 2));
    assert (p.line == 1 && p.character == 2);

    // start of buffer
    p = Vls.Foundation.offset_to_position (buf, 0);
    assert (p.line == 0 && p.character == 0);

    // UTF-8 multibyte
    var ubuf = "héllo\nwörld";
    p = Vls.Foundation.offset_to_position (ubuf, (long) Vls.Util.get_string_pos (ubuf, 1, 1));
    assert (p.line == 1 && p.character == 1);

    // CRLF
    var crlf = "a\r\nb";
    p = Vls.Foundation.offset_to_position (crlf, (long) Vls.Util.get_string_pos (crlf, 1, 0));
    assert (p.line == 1 && p.character == 0);

    // out-of-range clamps to end of buffer
    p = Vls.Foundation.offset_to_position (buf, 9999);
    assert (p.line == 2 && p.character == 5);

    // null buffer -> (0,0)
    var pn = Vls.Foundation.offset_to_position (null, 0);
    assert (pn.line == 0 && pn.character == 0);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/int_foundation/buffer_for", test_buffer_for);
    Test.add_func ("/int_foundation/slice_sourceref", test_slice_sourceref);
    Test.add_func ("/int_foundation/normalize_sourceref", test_normalize_sourceref);
    Test.add_func ("/int_foundation/position_from_sourceref", test_position_from_sourceref);
    Test.add_func ("/int_foundation/range_from_sourceref", test_range_from_sourceref);
    Test.add_func ("/int_foundation/offset_to_position", test_offset_to_position);
    return Test.run ();
}
