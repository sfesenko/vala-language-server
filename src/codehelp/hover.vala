/* hover.vala
 *
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;

namespace Vls.HoverHandler {
    void hover (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, "textDocument/hover");
                return;
            }

            Position pos = p.position;
            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);

            var resolved = Server.resolve_best_node (doc, pos);

            if (resolved == null) {
                Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            Vala.Scope scope = (new FindScope (doc, pos)).best_block.scope;
            var node = (!) resolved;
            // don't show lambda expressions on hover
            // don't show property accessors
            if (node is Vala.Method && ((Vala.Method)node).closure ||
                node is Vala.PropertyAccessor) {
                Server.reply_null (id, client, "textDocument/hover");
                Vala.CodeContext.pop ();
                return;
            }

            // the instance's data type, used to resolve the symbol, which may be a member
            Vala.DataType? data_type = null;
            Vala.List<Vala.DataType>? method_type_arguments = null;
            Vala.Symbol? symbol = null;

            if (node is Vala.Expression) {
                var expr = (Vala.Expression) node;
                symbol = expr.symbol_reference;
                data_type = expr.value_type;
                if (symbol != null && expr is Vala.MemberAccess) {
                    var ma = (Vala.MemberAccess) expr;
                    if (ma.inner != null && ma.inner.value_type != null) {
                        // get inner's data_type, which we can use to resolve expr's generic type
                        data_type = ma.inner.value_type;
                    }
                    method_type_arguments = ma.get_type_arguments ();
                }

                if (expr.parent_node is Vala.ObjectCreationExpression)
                    data_type = ((Vala.ObjectCreationExpression)expr.parent_node).value_type;

                // if data_type is the same as this variable's type, then this variable is not a member
                // of the type
                // (note: this avoids variable's generic type arguments being resolved to InvalidType)
                if (symbol is Vala.Variable && data_type != null && data_type.equals (((Vala.Variable)symbol).variable_type))
                    data_type = null;
            } else if (node is Vala.Symbol) {
                symbol = (Vala.Symbol) node;
            } else if (node is Vala.DataType) {
                data_type = (Vala.DataType) node;
                symbol = SymbolReferences.get_symbol_data_type_refers_to (data_type);
            } else if (node is Vala.UsingDirective) {
                symbol = ((Vala.UsingDirective)node).namespace_symbol;
            } else {
                warning ("node as %s not matched", node.type_name);
            }

            // don't show temporary variables
            if (symbol != null && symbol.name != null && symbol.name[0] == '.' && symbol.name[1].isdigit ()) {
                if (symbol is Vala.Variable && data_type == null)
                    data_type = ((Vala.Variable)symbol).variable_type;
                symbol = null;
            }

            var hoverInfo = new Hover ();

            Range? symbol_range = null;
            if (symbol != null) {
                symbol_range = SymbolReferences.get_replacement_range (node, symbol);
                if (symbol_range != null) {
                    // if the symbol range does not include the cursor, then try
                    // to get the hidden symbol at the cursor first
                    bool found_component = false;
                    if (!symbol_range.contains (pos)) {
                        foreach (var component in SymbolReferences.get_visible_components_of_code_node (node)) {
                            if (component.second.contains (pos)) {
                                hoverInfo.range = component.second;
                                symbol = component.first;
                                data_type = null;
                                method_type_arguments = null;
                                found_component = true;
                                break;
                            }
                        }
                    }
                    if (!found_component)
                        hoverInfo.range = symbol_range;
                }
            }

            if (symbol_range == null)
                hoverInfo.range = new Range.from_sourceref (node.source_reference);

            string? representation = CodeHelp.get_symbol_representation (data_type, symbol, scope, true, method_type_arguments);
            if (representation != null) {
                hoverInfo.contents.add (new MarkedString () {
                    language = "vala",
                    value = representation
                });

                if (symbol != null) {
                    var comment = server.get_symbol_documentation (project, symbol);
                    if (comment != null) {
                        hoverInfo.contents.add (new MarkedString () {
                            value = comment.body
                        });
                    }
                }
            }

            try {
                client.reply (id, Util.object_to_variant (hoverInfo), Server.cancellable);
            } catch (Error e) {
                warning ("[%s] failed to reply to client: %s", method, e.message);
            }

            Vala.CodeContext.pop ();
        });
    }
}
