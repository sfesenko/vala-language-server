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
    /**
     * textDocument/definition handler, piloted through the RequestHandler
     * framework. Reuses {@link Server.resolve_symbol_at} for the unwrap logic
     * that used to be hand-rolled here.
     */
    class DefinitionHandler : Server.RequestHandler {
        public DefinitionHandler (Server.RequestContext ctx) {
            base (ctx);
        }

        public override void run () {
            Lsp.Range? range;
            var node = Server.resolve_symbol_at (ctx, out range);
            if (node == null || range == null) {
                reply_null ();
                return;
            }
            var location = new Location (node.source_reference.file.filename, range);
            reply_object (location);
        }
    }

    void goto_definition (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? file = server.project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
            Server.cleanup_request (server, id);
            Server.reply_null (id, client, method);
            return;
        }

        server.context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.cleanup_request (server, id);
            Server.reply_null (id, client, method);
                return;
            }

            var ctx = new Server.RequestContext (server, client, id, method,
                                                 (!) file, compilation, project, p.position);
            Server.with_code_context (compilation.code_context, () => {
                var handler = new DefinitionHandler (ctx);
                handler.run ();
            });
        }, compilation);
    }

    /**
     * textDocument/references and textDocument/documentHighlight handler,
     * piloted through the RequestHandler framework. Shares the cursor
     * resolution + source-file iteration that used to be hand-rolled here.
     */
    class ReferencesHandler : Server.RequestHandler {
        private bool is_highlight;
        private bool include_declaration;

        public ReferencesHandler (Server.RequestContext ctx, bool is_highlight, bool include_declaration) {
            base (ctx);
            this.is_highlight = is_highlight;
            this.include_declaration = include_declaration;
        }

        public override void run () {
            var references = new Gee.HashMap<Range, Vala.CodeNode> ();

            var symbol = resolve_symbol ();
            if (symbol == null) {
                reply_null ();
                return;
            }

            debug ("[%s] got best: %s (%s)", ctx.method, symbol.to_string (), symbol.type_name);
            if (is_highlight || symbol is Vala.LocalVariable) {
                // if highlight, show references in current file
                // otherwise, we may also do this if it's a local variable, since
                // Server.get_compilations_using_symbol() only works for global symbols
                SymbolReferences.list_in_file (ctx.file, symbol, include_declaration, true, references);
            } else {
                // show references in all files
                var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget in ctx.project.get_compilations ())
                    generated_vapis.add_all (btarget.output);
                var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (ctx.project, symbol))
                    foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                        // don't show symbol from generated VAPI
                        var file = File.new_for_commandline_arg (project_file.filename);
                        if (file in generated_vapis || file in shown_files)
                            continue;
                        SymbolReferences.list_in_file (project_file, btarget_w_sym.second,
                                                        include_declaration, true, references);
                        shown_files.add (file);
                    }
            }

            debug ("[%s] found %d reference(s)", ctx.method, references.size);
            // Emit in a deterministic order (the underlying map is unordered).
            var entries = new Gee.ArrayList<Gee.Map.Entry<Range, Vala.CodeNode>> ();
            entries.add_all (references.entries);
            entries.sort ((a, b) => {
                int da = (int) a.key.start.line - (int) b.key.start.line;
                if (da != 0)
                    return da;
                return (int) a.key.start.character - (int) b.key.start.character;
            });
            var items = new Gee.ArrayList<Object> ();
            foreach (var entry in entries) {
                if (is_highlight) {
                    items.add (new DocumentHighlight () {
                        range = entry.key,
                        kind = determine_node_highlight_kind (entry.value)
                    });
                } else {
                    items.add (new Location (entry.value.source_reference.file.filename, entry.key));
                }
            }

            reply_array (items);
        }
    }

    /**
     * textDocument/implementation handler, piloted through the RequestHandler
     * framework. Reuses {@link Server.resolve_best_node} for cursor resolution
     * and the same per-file implementation search that used to be hand-rolled.
     */
    class ImplementationHandler : Server.RequestHandler {
        public ImplementationHandler (Server.RequestContext ctx) {
            base (ctx);
        }

        public override void run () {
            var resolved = Server.resolve_best_node (ctx.file, (!) ctx.pos);
            if (resolved == null) {
                debug ("[%s] no results found", ctx.method);
                reply_null ();
                return;
            }

            var node = (!) resolved;
            Vala.Symbol symbol;

            var references = new Gee.ArrayList<Vala.CodeNode> ();
            var items = new Gee.ArrayList<Object> ();

            if (node is Vala.DataType && ((Vala.DataType)node).type_symbol != null)
                node = ((Vala.DataType) node).type_symbol;

            debug ("[%s] got best: %s (%s)", ctx.method, node.to_string (), node.type_name);
            bool is_abstract_type = (node is Vala.Interface)
                || ((node is Vala.Class) && ((Vala.Class)node).is_abstract);
            bool is_abstract_or_virtual_method = (node is Vala.Method) &&
                (((Vala.Method)node).is_abstract || ((Vala.Method)node).is_virtual);
            bool is_abstract_or_virtual_property = (node is Vala.Property) &&
                (((Vala.Property)node).is_abstract || ((Vala.Property)node).is_virtual);

            if (!is_abstract_type && !is_abstract_or_virtual_method && !is_abstract_or_virtual_property) {
                debug ("[%s] best is neither an abstract type/interface nor abstract/virtual method/property", ctx.method);
                reply_null ();
                return;
            } else {
                symbol = (Vala.Symbol) node;
            }

            // show references in all files
            var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in ctx.project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (ctx.project, symbol)) {
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

            debug ("[%s] found %d reference(s)", ctx.method, references.size);
            foreach (var ref_node in references) {
                Vala.CodeNode real_node = ref_node;
                if (ref_node is Vala.Symbol)
                    real_node = SymbolReferences.find_real_symbol (ctx.project, (Vala.Symbol) ref_node);
                items.add (new Location.from_sourceref (real_node.source_reference));
            }

            reply_array (items);
        }
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

        Compilation compilation;
        Project project;
        Vala.SourceFile? doc = server.project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
            Server.cleanup_request (server, id);
            Server.reply_null (id, client, method);
            return;
        }

        server.context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.cleanup_request (server, id);
            Server.reply_null (id, client, method);
                return;
            }

            bool is_highlight = method == "textDocument/documentHighlight";
            bool include_declaration = p.context != null ? p.context.includeDeclaration : true;

            var ctx = new Server.RequestContext (server, client, id, method,
                                                 (!) doc, compilation, project, p.position);
            Server.with_code_context (compilation.code_context, () => {
                var handler = new ReferencesHandler (ctx, is_highlight, include_declaration);
                handler.run ();
            });
        }, compilation);
    }

    void show_implementations (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? doc = server.project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
            Server.cleanup_request (server, id);
            Server.reply_null (id, client, method);
            return;
        }

        server.context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.cleanup_request (server, id);
            Server.reply_null (id, client, method);
                return;
            }

            var ctx = new Server.RequestContext (server, client, id, method,
                                                 (!) doc, compilation, project, p.position);
            Server.with_code_context (compilation.code_context, () => {
                var handler = new ImplementationHandler (ctx);
                handler.run ();
            });
        }, compilation);
    }
}
