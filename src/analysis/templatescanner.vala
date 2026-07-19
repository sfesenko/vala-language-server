/* templatescanner.vala
 *
 * Copyright 2026 sfesenko
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Gee;

namespace Vls.Foundation {
    /**
     * A span representing an interpolated expression inside a template literal.
     * Covers the `$(expr)` or `$ident` portion.
     */
    public struct InterpolationSpan {
        public long start;
        public long end;
    }

    /**
     * A template literal found by the source-text scanner.  Contains the byte
     * range of the entire `@"…"` literal and the byte ranges of each
     * interpolation inside it.
     */
    public class ScannedTemplate {
        public long start;
        public long end;
        public ArrayList<InterpolationSpan?> interpolations = new ArrayList<InterpolationSpan?> ();
    }

    /**
     * Scan @a content for Vala template literals (`@"…"`).
     *
     * Returns a list of [[ScannedTemplate]] entries, one per template literal
     * found, in order of appearance.  Each entry contains the byte range of
     * the entire template and the byte ranges of its interpolations
     * (`$(expr)` or `$ident`).
     *
     * The scanner is context-independent: it depends only on the raw source
     * text, not on the Vala AST or semantic analysis.
     */
    public ArrayList<ScannedTemplate> scan_templates (string content) {
        var result = new ArrayList<ScannedTemplate> ();
        if (content == null || content.length == 0)
            return result;

        long i = 0;
        long len = content.length;

        while (i < len - 1) {
            // Look for @ followed by "
            if (content[i] == '@' && content[i + 1] == '"') {
                long tmpl_start = i;
                i += 2; // skip @"

                var interps = new ArrayList<InterpolationSpan?> ();

                while (i < len) {
                    char c = content[i];

                    if (c == '\\') {
                        // skip escaped character
                        i += 2;
                        continue;
                    }

                    if (c == '"') {
                        // end of template
                        break;
                    }

                    if (c == '$' && i + 1 < len) {
                        char next = content[i + 1];
                        if (next == '(') {
                            // $(...) interpolation
                            long interp_start = i;
                            i += 2; // skip $(
                            int depth = 1;
                            while (i < len && depth > 0) {
                                char ic = content[i];
                                if (ic == '(')
                                    depth++;
                                else if (ic == ')')
                                    depth--;
                                if (depth > 0)
                                    i++;
                            }
                            i++; // skip closing )
                            interps.add (InterpolationSpan () { start = interp_start, end = i });
                        } else if (next.isalpha () || next == '_') {
                            // $ident interpolation
                            long interp_start = i;
                            i += 2; // skip $ and first char of ident
                            while (i < len && (content[i].isalpha () || content[i].isdigit () || content[i] == '_'))
                                i++;
                            interps.add (InterpolationSpan () { start = interp_start, end = i });
                        } else {
                            i++;
                        }
                    } else {
                        i++;
                    }
                }

                var tmpl = new ScannedTemplate ();
                tmpl.start = tmpl_start;
                tmpl.end = i + 1; // include closing "
                tmpl.interpolations = interps;
                result.add (tmpl);
                i++; // skip closing "
            } else {
                i++;
            }
        }

        return result;
    }
}
