/* rename.vala
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

namespace Vls.Rename {
    void rename_symbol (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        string new_name = (string) @params.lookup_value ("newName", VariantType.STRING);

        // before anything, sanity-check the new symbol name
        if (!/^(?=[^\d])[^\s~`!#%^&*()\-\+={}\[\]|\\\/?.>,<'";:]+$/.match (new_name)) {
            client.reply_error_async.begin (
                id,
                Jsonrpc.ClientError.INVALID_REQUEST,
                "Invalid symbol name. Symbol names cannot start with a number and must not contain any operators.",
                Server.cancellable);
            return;
        }

        var p = Util.parse_variant<TextDocumentPositionParams> (@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Position pos = p.position;
            Project project;
            Compilation compilation;
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
            var references = new Gee.HashMap<Range, Vala.CodeNode> ();

            node = (!) Server.unwrap_to_symbol (node);

            // ignore lambda expressions and non-symbols
            if (!(node is Vala.Symbol) ||
                node is Vala.Method && ((Vala.Method)node).closure) {
                debug ("[%s] node is not a symbol", method);
                Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            symbol = (Vala.Symbol) node;

            debug ("[%s] got symbol %s @ %s", method, symbol.get_full_name (), symbol.source_reference.to_string ());

            // get references in all files
            var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            bool is_abstract_or_virtual =
                symbol is Vala.Property && (((Vala.Property)symbol).is_virtual || ((Vala.Property)symbol).is_abstract) ||
                symbol is Vala.Method && (((Vala.Method)symbol).is_virtual || ((Vala.Method)symbol).is_abstract) ||
                symbol is Vala.Signal && ((Vala.Signal)symbol).is_virtual;
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol))
                foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                    // don't show symbol from generated VAPI
                    var file = File.new_for_commandline_arg (project_file.filename);
                    if (file in generated_vapis || file in shown_files)
                        continue;
                    var file_references = new Gee.HashMap<Range, Vala.CodeNode> ();
                    debug ("[%s] looking for references in %s ...", method, file.get_uri ());
                    SymbolReferences.list_in_file (project_file, btarget_w_sym.second, true, false, file_references);
                    if (is_abstract_or_virtual) {
                        debug ("[%s] looking for implementations of abstract/virtual symbol in %s ...", method, file.get_uri ());
                        SymbolReferences.list_implementations_of_virtual_symbol (project_file, btarget_w_sym.second, file_references);
                    }
                    if (!(project_file is TextDocument) && file_references.size > 0) {
                        // This means we have found references in a file that was added automatically,
                        // which should not be modified.
                        debug ("[%s] disallowing requested modification of %s", method, project_file.filename);
                        Server.reply_null (id, client, method);
                        Vala.CodeContext.pop ();
                        return;
                    }
                    foreach (var entry in file_references)
                        references[entry.key] = entry.value;
                    shown_files.add (file);
                }

            debug ("[%s] found %d references", method, references.size);

            // construct the edits for the text documents
            // map: file URI -> TextEdit[]
            var edits = new Gee.HashMap<string, Gee.ArrayList<TextEdit>> ();
            var source_files = new Gee.HashMap<string, Vala.SourceFile> ();

            foreach (var entry in references) {
                var code_node = entry.value;
                var source_range = entry.key;
                debug ("[%s] editing reference %s @ %s ...",
                    method,
                    CodeHelp.get_code_node_source (code_node),
                    code_node.source_reference.to_string ());
                var file = File.new_for_commandline_arg (code_node.source_reference.file.filename);
                if (!edits.has_key (file.get_uri ()))
                    edits[file.get_uri ()] = new Gee.ArrayList<TextEdit> ();
                var file_edits = edits[file.get_uri ()];
                // if this is a using directive, we want to only replace the part after the 'using' keyword
                file_edits.add (new TextEdit (source_range, new_name));
                source_files[file.get_uri ()] = code_node.source_reference.file;
            }

            // TODO: determine support for TextDocumentEdit
            var text_document_edits_json = new Json.Array ();
            foreach (var uri in edits.keys) {
                var document_id = new VersionedTextDocumentIdentifier () {
                    version = ((TextDocument) source_files[uri]).version,
                    uri = uri
                };
                text_document_edits_json.add_element (Json.gobject_serialize (new TextDocumentEdit (document_id) {
                    edits = edits[uri]
                }));
            }

            try {
                Variant changes = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (text_document_edits_json), null);
                client.reply (
                    id,
                    server.build_dict (
                        documentChanges: changes
                    ),
                    Server.cancellable);
            } catch (Error e) {
                warning ("[%s] failed to reply to client - %s", method, e.message);
            }

            Vala.CodeContext.pop ();
        });
    }

    void prepare_rename_symbol (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<TextDocumentPositionParams> (@params);

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Position pos = p.position;
            Project project;
            Compilation compilation;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, p.textDocument.uri);
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);

            var resolved = Server.resolve_best_node (doc, pos);

            if (resolved == null) {
                client.reply_error_async.begin (
                    id,
                    Jsonrpc.ClientError.INVALID_REQUEST,
                    "There is no symbol at the cursor.",
                    Server.cancellable);
                Vala.CodeContext.pop ();
                return;
            }

            var initial_node = (!) resolved;
            var node = initial_node;
            Vala.Symbol symbol;

            node = (!) Server.unwrap_to_symbol (node);

            // ignore lambda expressions and non-symbols
            if (!(node is Vala.Symbol) ||
                node is Vala.Method && ((Vala.Method)node).closure) {
                // TODO: rewrite all code to use async
                client.reply_error_async.begin (
                    id,
                    Jsonrpc.ClientError.INVALID_REQUEST,
                    "There is no symbol at the cursor.",
                    Server.cancellable);
                Vala.CodeContext.pop ();
                return;
            }

            symbol = (Vala.Symbol) node;

            var replacement_range = SymbolReferences.get_replacement_range (initial_node, symbol);
            // If the source_reference is null, then this could be something like a
            // `this' parameter.
            if (replacement_range == null || symbol.source_reference == null) {
                client.reply_error_async.begin (
                    id,
                    Jsonrpc.ClientError.INVALID_REQUEST,
                    "There is no symbol at the cursor.",
                    Server.cancellable);
                Vala.CodeContext.pop ();
                return;
            }

            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
                if (!(btarget_w_sym.second.source_reference.file is TextDocument)) {
                    // This means we have found references in a file that was added automatically,
                    // which should not be modified.
                    // TODO: rewrite all code to use async
                    string? pkg = btarget_w_sym.second.source_reference.file.package_name;
                    client.reply_error_async.begin (
                        id,
                        Jsonrpc.ClientError.INVALID_REQUEST,
                        "Cannot rename a symbol defined in a system library" + (pkg != null ? @" ($pkg)." : "."),
                        Server.cancellable);
                    Vala.CodeContext.pop ();
                    return;
                }
            }

            try {
                client.reply (
                    id,
                    server.build_dict (
                        range: Util.object_to_variant (replacement_range),
                        placeholder: new Variant.string (symbol.name)
                    ),
                    Server.cancellable);
            } catch (Error e) {
                warning ("[%s] failed to reply with success - %s", method, e.message);
            }
            Vala.CodeContext.pop ();
        });
    }
}
