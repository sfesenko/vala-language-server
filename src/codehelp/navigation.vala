/* navigation.vala
 *
 * Copyright 2017-2019 Ben Iofel <ben@iofel.me>
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
using Gee;
using Lsp;

namespace Vls.Navigation {
    void goto_definition (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? file = server.find_file (p.textDocument.uri, out compilation, out project);
            if (file == null) {
                debug ("[%s] file `%s' not found", method, p.textDocument.uri);
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);
            var resolved = Server.resolve_best_node (file, p.position);

            if (resolved == null) {
                debug ("[%s] find symbol is empty", method);
                try {
                    client.reply (id, new Variant.maybe (VariantType.VARIANT, null), Server.cancellable);
                } catch (Error e) {
                    debug("[textDocument/definition] failed to reply to client: %s", e.message);
                }
                Vala.CodeContext.pop ();
                return;
            }

            var best = (!) resolved;

            if (best is Vala.Expression && !(best is Vala.Literal)) {
                var b = (Vala.Expression)best;
                debug ("best (%p) is a Expression (symbol_reference = %p)", best, b.symbol_reference);
                if (b.symbol_reference != null && b.symbol_reference.source_reference != null) {
                    best = b.symbol_reference;
                    debug ("best is now the symbol_referenece => %p (%s)", best, best.to_string ());
                }
            } else if (best is Vala.DataType) {
                best = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) best);
            } else if (best is Vala.UsingDirective) {
                best = ((Vala.UsingDirective)best).namespace_symbol;
            } else if (best is Vala.Method) {
                var m = (Vala.Method)best;

                if (m.base_interface_method != m && m.base_interface_method != null)
                    best = m.base_interface_method;
                else if (m.base_method != m && m.base_method != null)
                    best = m.base_method;
            } else if (best is Vala.Property) {
                var prop = (Vala.Property)best;

                if (prop.base_interface_property != prop && prop.base_interface_property != null)
                    best = prop.base_interface_property;
                else if (prop.base_property != prop && prop.base_property != null)
                    best = prop.base_property;
            } else {
                debug ("[%s] best is %s, which we can't handle", method, best != null ? best.type_name : null);
                try {
                    client.reply (id, new Variant.maybe (VariantType.VARIANT, null), Server.cancellable);
                } catch (Error e) {
                    debug("[textDocument/definition] failed to reply to client: %s", e.message);
                }
                Vala.CodeContext.pop ();
                return;
            }

            if (best is Vala.Symbol)
                best = SymbolReferences.find_real_symbol (project, (Vala.Symbol) best);

            var location = new Location.from_sourceref (best.source_reference);
            debug ("[textDocument/definition] found location ... %s", location.uri);
            try {
                client.reply (id, Util.object_to_variant (location), Server.cancellable);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            Vala.CodeContext.pop ();
        });
    }

    DocumentHighlightKind determine_node_highlight_kind (Vala.CodeNode node) {
        Vala.CodeNode? previous_node = node;

        for (Vala.CodeNode? current_node = node.parent_node;
             current_node != null;
             current_node = current_node.parent_node,
             previous_node = current_node) {
            if (current_node is Vala.MethodCall)
                return DocumentHighlightKind.Read;
            else if (current_node is Vala.Assignment) {
                if (previous_node == ((Vala.Assignment)current_node).left)
                    return DocumentHighlightKind.Write;
                else if (previous_node == ((Vala.Assignment)current_node).right)
                    return DocumentHighlightKind.Read;
            } else if (current_node is Vala.DeclarationStatement &&
                node == ((Vala.DeclarationStatement)current_node).declaration)
                return DocumentHighlightKind.Write;
            else if (current_node is Vala.ForeachStatement &&
                node == ((Vala.ForeachStatement)current_node).element_variable)
                return DocumentHighlightKind.Write;
            else if (current_node is Vala.Statement)
                return DocumentHighlightKind.Read;
        }

        return DocumentHighlightKind.Text;
    }

    void show_references (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<ReferenceParams>(@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            bool is_highlight = method == "textDocument/documentHighlight";
            bool include_declaration = p.context != null ? p.context.includeDeclaration : true;
            Position pos = p.position;

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, p.textDocument.uri);
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);

            var resolved = Server.resolve_best_node (doc, pos);

            if (resolved == null) {
                debug (@"[$method] no results found");
                Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            var node = (!) resolved;
            Vala.Symbol symbol;
            var json_array = new Json.Array ();
            var references = new Gee.HashMap<Range, Vala.CodeNode> ();

            node = (!) Server.unwrap_to_symbol (node);

            // ignore lambda expressions and non-symbols
            if (!(node is Vala.Symbol) ||
                node is Vala.Method && ((Vala.Method)node).closure) {
                Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            symbol = (Vala.Symbol) node;

            debug (@"[$method] got best: $node ($(node.type_name))");
            if (is_highlight || symbol is Vala.LocalVariable) {
                // if highlight, show references in current file
                // otherwise, we may also do this if it's a local variable, since
                // Server.get_compilations_using_symbol() only works for global symbols
                SymbolReferences.list_in_file (doc, symbol, include_declaration, true, references);
            } else {
                // show references in all files
                var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget in project.get_compilations ())
                    generated_vapis.add_all (btarget.output);
                var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol))
                    foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                        // don't show symbol from generated VAPI
                        var file = File.new_for_commandline_arg (project_file.filename);
                        if (file in generated_vapis || file in shown_files)
                            continue;
                        SymbolReferences.list_in_file (project_file, btarget_w_sym.second, include_declaration, true, references);
                        shown_files.add (file);
                    }
            }
            
            debug (@"[$method] found $(references.size) reference(s)");
            foreach (var entry in references) {
                if (is_highlight) {
                    json_array.add_element (Json.gobject_serialize (new DocumentHighlight () {
                        range = entry.key,
                        kind = determine_node_highlight_kind (entry.value)
                    }));
                } else {
                    json_array.add_element (Json.gobject_serialize (new Location (entry.value.source_reference.file.filename, entry.key)));
                }
            }

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, Server.cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    void show_implementations (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Position pos = p.position;

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, p.textDocument.uri);
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);

            var resolved = Server.resolve_best_node (doc, pos);

            if (resolved == null) {
                debug (@"[$method] no results found");
                Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            var node = (!) resolved;
            Vala.Symbol symbol;

            var json_array = new Json.Array ();
            var references = new Gee.ArrayList<Vala.CodeNode> ();

            if (node is Vala.DataType && ((Vala.DataType)node).type_symbol != null)
                node = ((Vala.DataType) node).type_symbol;

            debug (@"[$method] got best: $node ($(node.type_name))");
            bool is_abstract_type = (node is Vala.Interface) || ((node is Vala.Class) && ((Vala.Class)node).is_abstract);
            bool is_abstract_or_virtual_method = (node is Vala.Method) && 
                (((Vala.Method)node).is_abstract || ((Vala.Method)node).is_virtual);
            bool is_abstract_or_virtual_property = (node is Vala.Property) &&
                (((Vala.Property)node).is_abstract || ((Vala.Property)node).is_virtual);

            if (!is_abstract_type && !is_abstract_or_virtual_method && !is_abstract_or_virtual_property) {
                debug (@"[$method] best is neither an abstract type/interface nor abstract/virtual method/property");
                Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            } else {
                symbol = (Vala.Symbol) node;
            }

            // show references in all files
            var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
                foreach (var file in btarget_w_sym.first.code_context.get_source_files ()) {
                    var gfile = File.new_for_commandline_arg (file.filename);
                    // don't show symbol from generated VAPI
                    if (gfile in generated_vapis || gfile in shown_files)
                        continue;

                    NodeSearch fs2;
                    if (is_abstract_type) {
                        fs2 = new NodeSearch.with_filter (file, btarget_w_sym.second,
                        (needle, node) => node is Vala.ObjectTypeSymbol && 
                            ((Vala.ObjectTypeSymbol)node).is_subtype_of ((Vala.ObjectTypeSymbol) needle), false);
                    } else if (is_abstract_or_virtual_method) {
                        fs2 = new NodeSearch.with_filter (file, btarget_w_sym.second,
                        (needle, node) => needle != node && (node is Vala.Method) && 
                            (((Vala.Method)node).base_method == needle ||
                            ((Vala.Method)node).base_interface_method == needle), false);
                    } else {
                        fs2 = new NodeSearch.with_filter (file, symbol,
                        (needle, node) => needle != node && (node is Vala.Property) &&
                            (((Vala.Property)node).base_property == needle ||
                            ((Vala.Property)node).base_interface_property == needle), false);
                    }
                    references.add_all (fs2.result);
                    shown_files.add (gfile);
                }
            }

            debug (@"[$method] found $(references.size) reference(s)");
            foreach (var ref_node in references) {
                Vala.CodeNode real_node = ref_node;
                if (ref_node is Vala.Symbol)
                    real_node = SymbolReferences.find_real_symbol (project, (Vala.Symbol) ref_node);
                json_array.add_element (Json.gobject_serialize (new Location.from_sourceref (real_node.source_reference)));
            }

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, Server.cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }
}
