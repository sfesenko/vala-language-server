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

void test_line_index_byte_length_of_line () {
    // single line, no newline -> full length
    var one = new Vls.Foundation.LineIndex ("hello");
    assert (one.byte_length_of_line (0) == 5);

    // empty buffer -> 0
    var blank = new Vls.Foundation.LineIndex ("");
    assert (blank.byte_length_of_line (0) == 0);
    assert (blank.byte_length_of_line (99) == 0);

    // last line has no trailing newline
    var buf = "line0\nline1\nline2";
    var idx = new Vls.Foundation.LineIndex (buf);
    assert (idx.byte_length_of_line (0) == 5);  // "line0"
    assert (idx.byte_length_of_line (1) == 5);  // "line1"
    assert (idx.byte_length_of_line (2) == 5);  // "line2" (no '\n')
    assert (idx.byte_length_of_line (3) == 0);  // past end

    // a blank (just-newline) line counts as 0
    var nl = new Vls.Foundation.LineIndex ("a\n\nb");
    assert (nl.byte_length_of_line (1) == 0);

    // matches Vls.Util.line_byte_length on the same buffer
    for (uint l = 0; l < idx.line_count; l++)
        assert (idx.byte_length_of_line (l) == Vls.Foundation.line_byte_length (buf, l));
}

void test_slice_sourceref_with () {
    var ctx = new Vala.CodeContext ();
    var sf = new Vala.SourceFile (ctx, Vala.SourceFileType.SOURCE, "test.vala", "hello\nworld");
    var idx = new Vls.Foundation.LineIndex (sf.content);
    // forward ref: line 1 col 1 ("h") to line 1 col 5 ("o") -> "hello"
    var sr = new Vala.SourceReference (sf, loc ("test.vala", 1, 1), loc ("test.vala", 1, 5));
    var slice = Vls.Foundation.slice_sourceref_with (sr, idx);
    assert (slice == "hello");

    // matches the index-less slice_sourceref on the same buffer
    assert (Vls.Foundation.slice_sourceref (sr) == slice);

    // inverted ref -> null
    var inv = new Vala.SourceReference (sf, loc ("test.vala", 1, 5), loc ("test.vala", 1, 1));
    assert (Vls.Foundation.slice_sourceref_with (inv, idx) == null);

    // null index falls back to get_string_pos behavior
    assert (Vls.Foundation.slice_sourceref_with (sr, null) == "hello");
}

void test_offset_to_position () {
    var buf = "line0\nline1\nline2";
    // roundtrip with get_string_pos
    var p = Vls.Foundation.offset_to_position (buf, (long) Vls.Foundation.get_string_pos (buf, 1, 2));
    assert (p.line == 1 && p.character == 2);

    // start of buffer
    p = Vls.Foundation.offset_to_position (buf, 0);
    assert (p.line == 0 && p.character == 0);

    // UTF-8 multibyte
    var ubuf = "héllo\nwörld";
    p = Vls.Foundation.offset_to_position (ubuf, (long) Vls.Foundation.get_string_pos (ubuf, 1, 1));
    assert (p.line == 1 && p.character == 1);

    // CRLF
    var crlf = "a\r\nb";
    p = Vls.Foundation.offset_to_position (crlf, (long) Vls.Foundation.get_string_pos (crlf, 1, 0));
    assert (p.line == 1 && p.character == 0);

    // out-of-range clamps to end of buffer
    p = Vls.Foundation.offset_to_position (buf, 9999);
    assert (p.line == 2 && p.character == 5);

    // null buffer -> (0,0)
    var pn = Vls.Foundation.offset_to_position (null, 0);
    assert (pn.line == 0 && pn.character == 0);
}

void test_line_index () {
    // null content -> single line starting at 0
    var empty = new Vls.Foundation.LineIndex (null);
    assert (empty.line_count == 1);
    assert (empty.byte_offset (0) == 0);
    assert (empty.byte_offset (99) == 0); // past end clamps to length

    // empty string -> single line
    var blank = new Vls.Foundation.LineIndex ("");
    assert (blank.line_count == 1);
    assert (blank.byte_offset (0) == 0);

    // single line, no newline
    var one = new Vls.Foundation.LineIndex ("hello");
    assert (one.line_count == 1);
    assert (one.byte_offset (0) == 0);

    // many lines
    var buf = "line0\nline1\nline2\nline3";
    var idx = new Vls.Foundation.LineIndex (buf);
    assert (idx.line_count == 4);
    assert (idx.byte_offset (0) == 0);
    assert (idx.byte_offset (1) == 6);  // "line0\n"
    assert (idx.byte_offset (2) == 12); // + "line1\n"
    assert (idx.byte_offset (3) == 18); // + "line2\n"
    assert (idx.byte_offset (4) == buf.length); // past end clamps to length

    // byte_offset_for_char counts UTF-8 code points
    var uni = "héllo\nwörld";
    var uidx = new Vls.Foundation.LineIndex (uni);
    // "héllo\nwörld": line 0 "héllo" is 6 bytes, then '\n' at offset 6, so
    // line 1 "wörld" starts at offset 7. byte_offset_for_char counts UTF-8
    // code points within the line.
    assert (uidx.byte_offset_for_char (1, 0) == 7);   // 'w'
    assert (uidx.byte_offset_for_char (1, 1) == 8);   // 'ö' (first byte)
    assert (uidx.byte_offset_for_char (1, 2) == 10);  // after 'ö' (2-byte)
    assert (uidx.byte_offset_for_char (1, 3) == 11);  // 'r'

    // offset_to_position_with uses binary search over line starts
    var p = Vls.Foundation.offset_to_position_with (idx, 0);
    assert (p.line == 0 && p.character == 0);
    p = Vls.Foundation.offset_to_position_with (idx, 7);  // '1' on line 1
    assert (p.line == 1 && p.character == 1);
    p = Vls.Foundation.offset_to_position_with (idx, 20); // '3' on line 3
    assert (p.line == 3 && p.character == 2);
    p = Vls.Foundation.offset_to_position_with (idx, 9999); // clamps to end
    assert (p.line == 3 && p.character == 5);

    // CRLF counted by '\n' only
    var crlf = new Vls.Foundation.LineIndex ("a\r\nb");
    assert (crlf.line_count == 2);
    assert (crlf.byte_offset (1) == 3); // "a\r\n"
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/int_foundation/buffer_for", test_buffer_for);
    Test.add_func ("/int_foundation/slice_sourceref", test_slice_sourceref);
    Test.add_func ("/int_foundation/normalize_sourceref", test_normalize_sourceref);
    Test.add_func ("/int_foundation/position_from_sourceref", test_position_from_sourceref);
    Test.add_func ("/int_foundation/range_from_sourceref", test_range_from_sourceref);
    Test.add_func ("/int_foundation/offset_to_position", test_offset_to_position);
    Test.add_func ("/int_foundation/line_index", test_line_index);
    Test.add_func ("/int_foundation/line_index_byte_length_of_line", test_line_index_byte_length_of_line);
    Test.add_func ("/int_foundation/slice_sourceref_with", test_slice_sourceref_with);
    Test.add_func ("/int_foundation/textdocument_byte_offset", test_textdocument_byte_offset);
    return Test.run ();
}

void test_textdocument_byte_offset () {
    var ctx = new Vala.CodeContext ();
    var file = File.new_for_uri ("file:///vls_test_td.vala");
    var content = "line0\nline1\nline2";
    Vls.TextDocument doc;
    try {
        doc = new Vls.TextDocument (ctx, file, content);
    } catch (GLib.FileError e) {
        assert_not_reached ();
    }

    // matches the equivalent Foundation conversion (no per-call O(n) scan)
    var expected = Vls.Foundation.byte_offset (content, 1, 2);
    assert (doc.byte_offset (1, 2) == expected);
    assert (doc.byte_offset (0, 0) == 0);
    assert (doc.byte_offset (3, 5) == content.length);

    // cache is invalidated when content changes
    doc.content = "abc\nxyz";
    assert (doc.byte_offset (1, 0) == 4); // "abc\n"
    // and stays consistent after the change
    assert (doc.byte_offset (0, 2) == 2);
}
