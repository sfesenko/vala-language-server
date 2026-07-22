/* completion/helpers.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
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

using Lsp;
using Gee;

namespace Vls.CompletionEngine {
    const long MAX_BLOCK_SCAN_CHARS = 10000;

    /**
     * Extract the text from the start of the current line to the cursor position.
     */
    string extract_line_prefix (Vala.SourceFile doc, Position pos) {
        long idx = (long) Vls.Foundation.byte_offset (doc.content, pos.line, pos.character);
        long line_start = idx - pos.character;
        var prefix = new StringBuilder ();
        for (long i = line_start; i < idx; i++) {
            prefix.append_c (doc.content[i]);
        }
        return prefix.str;
    }

    /**
     * Check if the cursor is inside a comment (line or block).
     * Scans backwards from the cursor position for comment markers,
     * handling basic string quoting to reduce false positives.
     */
    bool cursor_in_comment (string content, Position pos) {
        long idx = Vls.Foundation.byte_offset (content, pos.line, pos.character);
        if (idx <= 0)
            return false;

        // Check for line comment: scan backwards on this line for `//`
        long line_start = idx;
        while (line_start > 0 && content[line_start - 1] != '\n')
            line_start--;

        bool in_string = false;
        bool in_triple_string_line = false;
        for (long i = line_start; i < idx - 1; i++) {
            // Check for triple-quoted string delimiter
            if (content[i] == '"' && i + 2 < content.length && content[i + 1] == '"' && content[i + 2] == '"') {
                in_triple_string_line = !in_triple_string_line;
                i += 2; // skip the next two quotes
                continue;
            }
            // Toggle single-quoted string state on unescaped `"`
            if (!in_triple_string_line && content[i] == '"' && (i == line_start || content[i - 1] != '\\'))
                in_string = !in_string;
            if (!in_string && !in_triple_string_line && content[i] == '/' && content[i + 1] == '/')
                return true;
        }

        // Check for block comment: scan backwards for `/*` without `*/` in between.
        // Track string quoting so `/*` inside a string doesn't produce false positive.
        // Cap scan to avoid O(n) on large files.
        int comment_depth = 0;
        bool in_block_string = false;
        bool in_triple_string = false;
        for (long i = idx - 1, scanned = 0; i >= 0 && scanned < MAX_BLOCK_SCAN_CHARS; i--, scanned++) {
            // Check for triple-quoted string delimiter (scan backward, so detect both
            // start delimiters at i,i+1,i+2 and end delimiters at i-2,i-1,i).
            if (content[i] == '"') {
                bool is_triple = false;
                if (i + 2 < content.length && content[i + 1] == '"' && content[i + 2] == '"') {
                    is_triple = true;
                    i += 2; // will be decremented by loop, net skip = +1
                    scanned += 2;
                } else if (i >= 2 && content[i - 1] == '"' && content[i - 2] == '"') {
                    is_triple = true;
                    i -= 2; // will be decremented by loop, net skip = -3
                    scanned += 2;
                }
                if (is_triple) {
                    in_triple_string = !in_triple_string;
                    continue;
                }
            }
            // Toggle single-quoted string state on unescaped `"`
            if (!in_triple_string && content[i] == '"' && (i == 0 || content[i - 1] != '\\')) {
                in_block_string = !in_block_string;
                continue;
            }
            if (in_block_string || in_triple_string)
                continue;
            if (i < idx - 1 && content[i] == '*' && content[i + 1] == '/') {
                comment_depth++;
            } else if (content[i] == '/' && i + 1 < content.length && content[i + 1] == '*') {
                if (comment_depth > 0)
                    comment_depth--;
                else
                    return true;
            }
        }
        return comment_depth > 0;
    }

    void finish (Server server, Jsonrpc.Client client, Variant id, Collection<CompletionItem> completions) {
        var items = new ArrayList<Object> ();
        foreach (CompletionItem comp in completions)
            items.add (comp);
        Server.reply_array (client, id, items);
        Server.cleanup_request (server, id);
    }

    void walk_up_current_scope (Server.ServiceProvider lang_serv,
                                Vala.SourceFile doc, Position pos,
                                out Vala.Scope best_scope, out Vala.Symbol nearest_symbol,
                                out Vala.Expression? nearest_with_expression,
                                out bool in_loop) {
        best_scope = new FindScope (doc, pos).best_block.scope;
        in_loop = false;
        nearest_symbol = null;
        nearest_with_expression = null;
        for (Vala.Scope? scope = best_scope;
             scope != null;
             scope = scope.parent_scope) {
            Vala.Symbol owner = scope.owner;
            if (owner.parent_node is Vala.WhileStatement ||
                owner.parent_node is Vala.ForStatement ||
                owner.parent_node is Vala.ForeachStatement ||
                owner.parent_node is Vala.DoStatement ||
                owner.parent_node is Vala.Loop)
                in_loop = true;
#if VALA_0_50
            if (nearest_with_expression == null && owner.parent_node is Vala.WithStatement)
                nearest_with_expression = ((Vala.WithStatement)owner.parent_node).expression;
#endif

            if (owner is Vala.Callable || owner is Vala.Statement || owner is Vala.Block ||
                owner is Vala.Subroutine) {
                if (owner is Vala.Method) {
                    if (nearest_symbol == null)
                        nearest_symbol = owner;
                }
            } else if (owner is Vala.TypeSymbol) {
                if (nearest_symbol == null)
                    nearest_symbol = owner;
            } else if (owner is Vala.Namespace) {
                if (nearest_symbol == null)
                    nearest_symbol = owner;
            }
        }

        if (nearest_symbol == null)
            nearest_symbol = best_scope.owner;
    }

    Vala.Scope get_topmost_scope (Vala.Scope topmost) {
        for (Vala.Scope? current_scope = topmost;
             current_scope != null;
             current_scope = current_scope.parent_scope)
            topmost = current_scope;

        return topmost;
    }
}
