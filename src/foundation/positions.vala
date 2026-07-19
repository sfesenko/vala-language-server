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
    public string? slice_sourceref (Vala.SourceReference? sr) {
        if (sr == null || sr.file == null)
            return null;
        var buf = buffer_for (sr.file);
        if (buf == null)
            return null;
        long from = (long) Util.get_string_pos (buf, (uint) (sr.begin.line - 1), (uint) (sr.begin.column - 1));
        long to = (long) Util.get_string_pos (buf, (uint) (sr.end.line - 1), (uint) (sr.end.column));
        if (to < from)
            return null;
        return buf[from:to];
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
     * Convert a byte offset in [buf] to a position (zero-based line,
     * zero-based UTF-8 character column).
     *
     * UTF-8 and CRLF safe: lines are counted by {@code '\n'}, and the
     * character column counts Unicode code points (via {@link string.next_char}),
     * so it is the inverse of {@link Vls.Util.get_string_pos}. The offset is
     * clamped to the buffer bounds.
     */
    public Position offset_to_position (string? buf, long byte_off) {
        var pos = Position ();
        if (buf == null)
            return pos;
        long total = buf.length;
        if (byte_off < 0)
            byte_off = 0;
        if (byte_off > total)
            byte_off = total;
        uint line = 0;
        for (long i = 0; i < byte_off; i++) {
            if (buf[i] == '\n')
                line++;
        }
        long line_start = byte_off;
        for (long j = byte_off - 1; j >= 0; j--) {
            if (buf[j] == '\n') {
                line_start = j + 1;
                break;
            }
        }
        string line_str = buf.substring ((long) line_start, (long) (byte_off - line_start));
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
}
