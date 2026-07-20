/* positions.vala
 *
 * Foundation: position / range / buffer utilities for VLS.
 *
 * These helpers are the single source of truth for converting Vala source
 * references into positions/ranges and for obtaining the consistent
 * content buffer of a file. They are null-safe and tested so that the
 * crash classes rooted in missing foundations cannot recur.
 *
 * This module is deliberately LSP-protocol-free: it works in terms of its
 * own lightweight {@link Position}/{@link Range} value types. The LSP
 * bindings in protocol.vala delegate to it, so the math lives in exactly
 * one tested place.
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
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;

namespace Vls.Foundation {
    /**
     * A zero-based (line, character) position, mirroring {@link Lsp.Position}.
     */
    public struct Position {
        public uint line;
        public uint character;
    }

    /**
     * A range between two {@link Position}s, mirroring {@link Lsp.Range}.
     */
    public struct Range {
        public Position start;
        public Position end;
    }

    /**
     * One consistent content buffer for a file.
     *
     * Returns {@link Vls.TextDocument.last_fresh_content} for a
     * {@link Vls.TextDocument} (the buffer that was actually parsed/compiled),
     * and the mapped {@link Vala.SourceFile.content} otherwise. This fixes the
     * latent buffer-mismatch bug where offsets were computed against one buffer
     * and then sliced from another.
     *
     * Returns null only when the file is null.
     */
    public unowned string? buffer_for (Vala.SourceFile? file) {
        if (file == null)
            return null;
        if (file is TextDocument) {
            return ((TextDocument) file).last_fresh_content;
        }
        if (file.content == null)
            file.content = (string) file.get_mapped_contents ();
        return file.content;
    }

    /**
     * Slice the source text covered by [sr] using the file's consistent buffer
     * (see {@link buffer_for}).
     *
     * Returns null when [sr] or its buffer is unavailable, or when the
     * reference is inverted (end before begin).
     */
    /**
     * Slice the source text covered by [sr] using a pre-built {@link LineIndex}
     * for [sr.file]'s buffer. The slice is taken from the index's own buffer
     * (the one it was built from), so the computed byte offsets are always
     * consistent. This is O(1)–O(log n) per call, replacing the two O(buffer)
     * {@link Vls.Util.get_string_pos} scans that {@link slice_sourceref}
     * performs on every call — important for callers that invoke it once per
     * source reference during an AST walk.
     *
     * Pass a null [index] to fall back to {@link slice_sourceref}'s behavior.
     */
    public string? slice_sourceref_with (Vala.SourceReference? sr, LineIndex? index) {
        if (sr == null || sr.file == null)
            return null;
        // Vala always uses 1-based lines/columns, but guard against a
        // pathological 0 (which would wrap to uint.MAX on subtraction below)
        // before delegating to the normalizing range math.
        if (sr.begin.line < 1 || sr.begin.column < 1 || sr.end.line < 1 || sr.end.column < 1)
            return null;
        unowned string? buf = index != null ? index.content : buffer_for (sr.file);
        if (buf == null)
            return null;
        long from = index != null
            ? index.byte_offset_for_char ((uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1))
            : (long) Util.get_string_pos (buf, (uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
        long to = index != null
            ? index.byte_offset_for_char ((uint) (sr.end.line - 1), (uint) sr.end.column)
            : (long) Util.get_string_pos (buf, (uint) (sr.end.line - 1), (uint) sr.end.column);
        if (to < from)
            return null;
        return buf[from:to];
    }

    /**
     * Slice the source text covered by [sr] using the file's consistent buffer
     * (see {@link buffer_for}). Convenience wrapper around
     * {@link slice_sourceref_with} with no index.
     */
    public string? slice_sourceref (Vala.SourceReference? sr) {
        return slice_sourceref_with (sr, null);
    }

    private static bool location_before (Vala.SourceLocation a, Vala.SourceLocation b) {
        if (a.line != b.line)
            return a.line < b.line;
        return a.column < b.column;
    }

    private static Vala.SourceLocation clamp_location (Vala.SourceLocation loc, string filename) {
        int line = loc.line < 1 ? 1 : loc.line;
        int col = loc.column < 1 ? 1 : loc.column;
        return Vala.SourceLocation (filename, line, col);
    }

    /**
     * Return a normalized copy of [sr]: swap begin/end if inverted, and clamp
     * line/column to valid (>= 1) bounds. Returns null when [sr] is null.
     */
    public Vala.SourceReference? normalize_sourceref (Vala.SourceReference? sr) {
        if (sr == null)
            return null;
        var begin = sr.begin;
        var end = sr.end;
        if (location_before (end, begin)) {
            var tmp = begin;
            begin = end;
            end = tmp;
        }
        string filename = sr.file != null ? sr.file.filename : "";
        begin = clamp_location (begin, filename);
        end = clamp_location (end, filename);
        return new Vala.SourceReference ((!) sr.file, begin, end);
    }

    /**
     * Robust position for the start of [sr] (null-safe).
     *
     * Following the convention of {@link Lsp.Position.from_libvala}, the
     * resulting character is the source column minus one (zero-based, inclusive).
     */
    public Position position_from_sourceref (Vala.SourceReference? sr) {
        var pos = Position ();
        if (sr == null || sr.file == null)
            return pos;
        pos.line = (uint) sr.begin.line - 1;
        pos.character = (uint) sr.begin.column - 1;
        return pos;
    }

    /**
     * Robust range from [sr] (null-safe).
     *
     * Wraps {@link normalize_sourceref} so an inverted reference can never
     * produce an inverted range. The end position is half-open (exclusive)
     * following LSP convention: {@code end.character == sr.end.column}.
     */
    public Range range_from_sourceref (Vala.SourceReference? sr) {
        var range = Range ();
        if (sr == null || sr.file == null)
            return range;
        var norm = normalize_sourceref (sr);
        if (norm == null)
            return range;
        range.start = position_from_sourceref (norm);
        range.end = Position () {
            line = (uint) norm.end.line - 1,
            character = (uint) norm.end.column,
        };
        return range;
    }

    /**
     * Zero-allocation index of line-start byte offsets for a buffer.
     *
     * Built once per buffer, it turns the repeated O(n) scans that
     * {@link Util.get_string_pos} / {@link offset_to_position} otherwise
     * perform into O(1)/O(log n) lookups. The buffer is held unowned, so the
     * index must not outlive the content it was built from.
     */
    public class LineIndex {
        private unowned string? buf;
        // Byte offset of the first character of each line (line 0 starts at 0).
        private long[] line_starts = {};

        /**
         * The buffer this index was built from, or null.
         */
        public unowned string? content {
            get { return buf; }
        }

        public LineIndex (string? content) {
            buf = content;
            if (buf == null || buf.length == 0) {
                line_starts = new long[] { 0 };
                return;
            }
            // First pass: count newlines to size the array exactly.
            long count = 1;
            for (long i = 0; i < buf.length; i++)
                if (buf[i] == '\n')
                    count++;
            line_starts = new long[count];
            // Second pass: record each line's start offset.
            long idx = 0;
            line_starts[idx++] = 0;
            for (long i = 0; i < buf.length; i++)
                if (buf[i] == '\n')
                    line_starts[idx++] = i + 1;
        }

        /**
         * Byte offset of the first character on [line] (zero-based). Lines past
         * the end of the buffer return the buffer length.
         */
        public long byte_offset (uint line) {
            if (buf == null)
                return 0;
            if (line >= line_starts.length)
                return buf.length;
            return line_starts[line];
        }

        /**
         * Number of lines recorded (one more than the newline count).
         */
        public uint line_count {
            get { return (uint) line_starts.length; }
        }

        /**
         * Number of bytes in [line] (excluding any trailing newline). Returns
         * 0 for lines past the end of the buffer. Uses the precomputed line
         * starts, so it is an allocation-free, O(1) replacement for
         * {@link Vls.Util.line_byte_length} when a {@link LineIndex} is already
         * built for the buffer.
         */
        public long byte_length_of_line (uint line) {
            if (buf == null || line >= line_starts.length)
                return 0;
            long start = line_starts[line];
            long end = (line + 1 < line_starts.length) ? line_starts[line + 1] : buf.length;
            // strip the trailing newline so the result matches
            // Vls.Util.line_byte_length (which stops at '\n')
            if (end > start && buf[end - 1] == '\n')
                end--;
            return end - start;
        }

        /**
         * Byte offset of the [charno]-th UTF-8 code point on [line]
         * (both zero-based). Equivalent to {@link Vls.Util.get_string_pos} but
         * O(chars-in-line) instead of O(bytes-in-buffer).
         */
        public long byte_offset_for_char (uint line, uint charno) {
            long start = byte_offset (line);
            if (buf == null)
                return start;
            long cur = start;
            uint c = 0;
            while (c < charno && cur < buf.length && buf[cur] != '\0') {
                cur++;
                // Skip UTF-8 continuation bytes of this code point.
                while (cur < buf.length && (buf[cur] & 0xC0) == 0x80)
                    cur++;
                c++;
            }
            return cur;
        }
    }

    /**
     * Convert a byte offset to a position using a pre-built {@link LineIndex}.
     *
     * Prefer this over {@link offset_to_position} when converting many offsets
     * against the same buffer: the index is built once and reused, so the
     * per-call cost is O(log n) (binary search over line starts) instead of
     * rescanning the buffer each time.
     */
    public Position offset_to_position_with (LineIndex index, long byte_off) {
        var pos = Position ();
        if (index.content == null)
            return pos;
        string buf = index.content;
        long total = buf.length;
        if (byte_off < 0)
            byte_off = 0;
        if (byte_off > total)
            byte_off = total;
        // Find the line whose start is the greatest offset <= byte_off.
        // line_starts is sorted ascending, so binary search is safe.
        uint lo = 0, hi = index.line_count;
        while (lo < hi) {
            uint mid = lo + (hi - lo) / 2;
            if (index.byte_offset (mid) <= byte_off)
                lo = mid + 1;
            else
                hi = mid;
        }
        uint line = lo > 0 ? lo - 1 : 0;
        long line_start = index.byte_offset (line);
        string line_str = buf.substring (line_start, byte_off - line_start);
        uint character = 0;
        string p = line_str;
        while (p[0] != '\0') {
            p = p.next_char ();
            character++;
        }
        pos.line = line;
        pos.character = character;
        return pos;
    }

    /**
     * Convert a byte offset in [buf] to a position (zero-based line,
     * zero-based UTF-8 character column).
     *
     * UTF-8 and CRLF safe: lines are counted by {@code '\n'}, and the
     * character column counts Unicode code points (via {@link string.next_char}),
     * so it is the inverse of {@link Vls.Util.get_string_pos}. The offset is
     * clamped to the buffer bounds.
     *
     * This convenience wrapper builds a fresh {@link LineIndex} on every call,
     * so it is O(buffer) per invocation (suitable for one-shot callers). For
     * repeated conversions against the same buffer, build a {@link LineIndex}
     * once and use {@link offset_to_position_with} instead — its binary search
     * keeps the per-call cost at O(log n).
     */
    public Position offset_to_position (string? buf, long byte_off) {
        if (buf == null)
            return Position ();
        return offset_to_position_with (new LineIndex (buf), byte_off);
    }

    /**
     * Convert a zero-based (line, character) position to a byte offset in
     * [buf], the inverse of {@link offset_to_position}.
     *
     * This is a drop-in replacement for {@link Vls.Util.get_string_pos}: it
     * takes the same zero-based line/character convention and returns the same
     * byte offset, but builds a {@link LineIndex} once per call. For repeated
     * conversions against the same buffer (e.g. a {@link Vls.TextDocument}),
     * cache the index and call {@link LineIndex.byte_offset_for_char}
     * directly to avoid rebuilding it each time.
     */
    public long byte_offset (string? buf, uint line, uint character) {
        if (buf == null)
            return 0;
        return new LineIndex (buf).byte_offset_for_char (line, character);
    }
}
