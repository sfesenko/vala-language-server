/* symbolresolver.vala
 *
 * AST resolution utilities extracted from Server.
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

using Lsp;

namespace Vls.SymbolResolver {
    Vala.CodeNode get_best (NodeSearch fs, Vala.SourceFile file) {
        Vala.CodeNode? best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else {
                var best_begin = new Position.from_libvala (best.source_reference.begin);
                var best_end = new Position.from_libvala (best.source_reference.end);
                var node_begin = new Position.from_libvala (node.source_reference.begin);
                var node_end = new Position.from_libvala (node.source_reference.end);

                bool same_range = best_begin.compare_to (node_begin) == 0
                    && node_end.compare_to (best_end) == 0;
                bool node_inside_best = best_begin.compare_to (node_begin) <= 0
                    && node_end.compare_to (best_end) <= 0;

                if (same_range) {
                    // Tie-breaker for equal-ranged candidates.
                    // Original rule: keep [best] unless one of the special
                    // equivalences (LocalVariable, Field/Property,
                    // NullLiteral/Method) applies — the visitor order wins
                    // ties in that case. On top of that, prefer a candidate
                    // that resolves to a real user-visible symbol over a
                    // synthetic wrapper. This matters for template
                    // interpolations: Vala rewrites "$x" into
                    // "(x).to_string(\"%i\")", and the rewritten MethodCall
                    // inherits the inner expression's source reference, so
                    // both the MethodCall (symbol = builtin to_string) and
                    // the inner MemberAccess (symbol = the real local var)
                    // match the cursor. Without this tie-breaker the natural
                    // visitor order picks the wrapper, hiding the variable's
                    // actual type behind string (the to_string return type).
                    bool special_equiv = (best is Vala.LocalVariable && node is Vala.LocalVariable)
                        || (best is Vala.Field && node is Vala.Property)
                        || (best is Vala.NullLiteral && node is Vala.Method);
                    if (special_equiv) {
                        best = node;
                        continue;
                    }
                    bool best_has_real_sym = best is Vala.Symbol
                        || (best is Vala.Expression
                            && ((Vala.Expression) best).symbol_reference != null
                            && !is_synthetic_wrapper_symbol (((Vala.Expression) best).symbol_reference));
                    bool node_has_real_sym = node is Vala.Symbol
                        || (node is Vala.Expression
                            && ((Vala.Expression) node).symbol_reference != null
                            && !is_synthetic_wrapper_symbol (((Vala.Expression) node).symbol_reference));
                    if (node_has_real_sym && !best_has_real_sym)
                        best = node;
                } else if (node_inside_best) {
                    best = node;
                }
            }
        }
        return (!) best;
    }

    // Returns true if [sym] is one of the synthetic helpers Vala inserts
    // when rewriting template literals (@"...") into concat/to_string chains.
    // Clicking on a $(expr) interpolation should resolve to the user's real
    // expr, not to to_string / concat that wrap it.
    private static bool is_synthetic_wrapper_symbol (Vala.Symbol sym) {
        if (sym is Vala.Method) {
            var name = sym.name;
            if (name == "to_string" || name == "concat"
                || (sym.parent_symbol != null && sym.parent_symbol.name == "string"))
                return true;
        }
        return false;
    }

    Vala.CodeNode? resolve_best_node (Vala.SourceFile file, Position pos,
                                              bool search_multiline = true) {
        var fs = new NodeSearch (file, pos, search_multiline);
        if (fs.result.size == 0)
            return null;
        return get_best (fs, file);
    }

    Vala.CodeNode? unwrap_to_symbol (Vala.CodeNode node) {
        if (node is Vala.Expression && ((Vala.Expression) node).symbol_reference != null)
            return ((Vala.Expression) node).symbol_reference;
        if (node is Vala.DataType)
            return SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) node);
        if (node is Vala.UsingDirective && ((Vala.UsingDirective) node).namespace_symbol != null)
            return ((Vala.UsingDirective) node).namespace_symbol;
        return node;
    }

    Vala.CodeNode? resolve_symbol_at (Server.RequestContext ctx, out Lsp.Range? range) {
        range = null;
        var resolved = resolve_best_node (ctx.file, (!) ctx.pos);
        if (resolved == null)
            return null;

        Vala.CodeNode best = (!) resolved;

        // A cursor on a literal (string/int/bool/char …) does not point at
        // a user-navigable symbol — bail out instead of reporting a "goto
        // self" Location covering the literal itself. (The classic case is
        // a word inside a plain "…" string literal, which resolves to the
        // Vala.StringLiteral and would previously report itself as the
        // definition target; see hover.vala for the matching hover guard.)
        if (best is Vala.StringLiteral || best is Vala.IntegerLiteral
            || best is Vala.RealLiteral || best is Vala.BooleanLiteral
            || best is Vala.CharacterLiteral || best is Vala.NullLiteral
            || best is Vala.RegexLiteral)
            return null;

        Vala.Symbol? best_sym = best as Vala.Symbol;

        if (best is Vala.Expression && !(best is Vala.Literal)) {
            var b = (Vala.Expression) best;
            if (b.symbol_reference != null && b.symbol_reference.source_reference != null)
                best_sym = b.symbol_reference;
        } else if (best is Vala.DataType) {
            best_sym = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) best) ?? best_sym;
        } else if (best is Vala.UsingDirective) {
            var ns = ((Vala.UsingDirective) best).namespace_symbol;
            if (ns != null)
                best_sym = ns;
        } else if (best is Vala.MemberAccess) {
            var inner = ((Vala.MemberAccess) best).inner;
            if (inner != null && inner.symbol_reference != null)
                best_sym = inner.symbol_reference;
        }

        if (best_sym is Vala.Method) {
            var method = (Vala.Method) best_sym;
            if (method.base_method != null)
                best_sym = method.base_method;
        } else if (best_sym is Vala.Property) {
            var prop = (Vala.Property) best_sym;
            if (prop.base_property != null)
                best_sym = prop.base_property;
        }

        var real_sym = SymbolReferences.find_real_symbol (ctx.project, best_sym);
        if (real_sym != null)
            best = real_sym;
        else if (best_sym != null)
            best = best_sym;

        if (best.source_reference != null)
            range = new Lsp.Range.from_sourceref (best.source_reference);

        return best;
    }
}
