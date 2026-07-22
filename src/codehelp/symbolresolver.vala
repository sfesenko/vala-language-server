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

                if (best_begin.compare_to (node_begin) <= 0 && node_end.compare_to (best_end) <= 0 &&
                    (!(best_begin.compare_to (node_begin) == 0 && node_end.compare_to (best_end) == 0) ||
                    (best is Vala.LocalVariable && node is Vala.LocalVariable) ||
                    (best is Vala.Field && node is Vala.Property) ||
                    (best is Vala.NullLiteral && node is Vala.Method)
                )) {
                    best = node;
                }
            }
        }
        return (!) best;
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
