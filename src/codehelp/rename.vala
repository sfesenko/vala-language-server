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
    /**
     * textDocument/rename handler, piloted through the RequestHandler
     * framework. The new-name sanity check stays in the dispatch function
     * (it runs before the context is acquired, matching the old behavior).
     */
    class RenameHandler : Server.RequestHandler {
        private string new_name;

        public RenameHandler (Server.RequestContext ctx, string new_name) {
            base (ctx);
            this.new_name = new_name;
        }

        public override void run () {
            var symbol = resolve_symbol ();
            if (symbol == null) {
                Logger.debug ("lsp", "no results found");
                reply_null ();
                return;
            }
            if (symbol.source_reference == null) {
                Logger.debug ("lsp", "symbol %s has no source reference", symbol.get_full_name ());
                reply_null ();
                return;
            }

            Logger.debug ("lsp", "got symbol %s @ %s", symbol.get_full_name (), symbol.source_reference.to_string ());

            // get references in all files
            var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in ctx.project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
            bool is_abstract_or_virtual =
                symbol is Vala.Property && (((Vala.Property)symbol).is_virtual || ((Vala.Property)symbol).is_abstract) ||
                symbol is Vala.Method && (((Vala.Method)symbol).is_virtual || ((Vala.Method)symbol).is_abstract) ||
                symbol is Vala.Signal && ((Vala.Signal)symbol).is_virtual;
            var references = new Gee.HashMap<Range, Vala.CodeNode> ();
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (ctx.project, symbol))
                foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                    // don't show symbol from generated VAPI
                    var file = File.new_for_commandline_arg (project_file.filename);
                    if (file in generated_vapis || file in shown_files)
                        continue;
                    var file_references = new Gee.HashMap<Range, Vala.CodeNode> ();
                    Logger.debug ("lsp", "looking for references in %s", file.get_uri ());
                    SymbolReferences.list_in_file (project_file, btarget_w_sym.second, true, false, file_references);
                    if (is_abstract_or_virtual) {
                        Logger.debug ("lsp", "looking for implementations of abstract/virtual symbol in %s", file.get_uri ());
                        SymbolReferences.list_implementations_of_virtual_symbol (project_file, btarget_w_sym.second, file_references);
                    }
                    if (!(project_file is TextDocument) && file_references.size > 0) {
                        // This means we have found references in a file that was added automatically,
                        // which should not be modified.
                        Logger.warn ("lsp", "disallowing requested modification of %s", project_file.filename);
                        reply_null ();
                        return;
                    }
                    foreach (var entry in file_references)
                        references[entry.key] = entry.value;
                    shown_files.add (file);
                }

            Logger.debug ("lsp", "found %d references", references.size);

            // construct the edits for the text documents
            // map: file URI -> TextEdit[]
            var edits = new Gee.HashMap<string, Gee.ArrayList<TextEdit>> ();
            var source_files = new Gee.HashMap<string, Vala.SourceFile> ();

            // Emit edits in a deterministic order (references is an unordered map).
            var ref_entries = new Gee.ArrayList<Gee.Map.Entry<Range, Vala.CodeNode>> ();
            ref_entries.add_all (references.entries);
            ref_entries.sort ((a, b) => {
                int da = (int) a.key.start.line - (int) b.key.start.line;
                if (da != 0)
                    return da;
                return (int) a.key.start.character - (int) b.key.start.character;
            });
            foreach (var entry in ref_entries) {
                var code_node = entry.value;
                var source_range = entry.key;
                Logger.debug ("lsp", "editing reference %s @ %s ...",
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
            var uris = new Gee.ArrayList<string> ();
            uris.add_all (edits.keys);
            uris.sort ((a, b) => GLib.strcmp (a, b));
            foreach (var uri in uris) {
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
                reply_dict (ctx.server.build_dict (documentChanges: changes));
            } catch (Error e) {
                Logger.warn ("lsp", "failed to reply to client - %s", e.message);
            }
        }
    }

    /**
     * textDocument/prepareRename handler, piloted through the RequestHandler
     * framework. Errors are reported via {@link Jsonrpc.Client.reply_error_async}
     * (matching the old behavior); the success reply is a variant dict.
     */
    class PrepareRenameHandler : Server.RequestHandler {
        public PrepareRenameHandler (Server.RequestContext ctx) {
            base (ctx);
        }

        public override void run () {
            var pos = (!) ctx.pos;
            var doc = ctx.file;

            var resolved = Server.resolve_best_node (doc, pos);

            if (resolved == null) {
                reply_error (Jsonrpc.ClientError.INVALID_REQUEST, "There is no symbol at the cursor.");
                return;
            }

            var initial_node = (!) resolved;
            var node = initial_node;
            Vala.Symbol symbol;

            node = (!) Server.unwrap_to_symbol (node);

            // ignore lambda expressions and non-symbols
            if (!(node is Vala.Symbol) ||
                node is Vala.Method && ((Vala.Method)node).closure) {
                reply_error (Jsonrpc.ClientError.INVALID_REQUEST, "There is no symbol at the cursor.");
                return;
            }

            symbol = (Vala.Symbol) node;

            var replacement_range = SymbolReferences.get_replacement_range (initial_node, symbol);
            // If the source_reference is null, then this could be something like a
            // `this' parameter.
            if (replacement_range == null || symbol.source_reference == null) {
                reply_error (Jsonrpc.ClientError.INVALID_REQUEST, "There is no symbol at the cursor.");
                return;
            }

            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (ctx.project, symbol)) {
                if (!(btarget_w_sym.second.source_reference.file is TextDocument)) {
                    // This means we have found references in a file that was added automatically,
                    // which should not be modified.
                    string? pkg = btarget_w_sym.second.source_reference.file.package_name;
                    reply_error (Jsonrpc.ClientError.INVALID_REQUEST,
                        "Cannot rename a symbol defined in a system library" + (pkg != null ? @" ($pkg)." : "."));
                    return;
                }
            }

            try {
                reply_dict (ctx.server.build_dict (
                    range: Util.object_to_variant (replacement_range),
                    placeholder: new Variant.string (symbol.name)
                ));
            } catch (Error e) {
                Logger.warn ("lsp", "failed to reply with success - %s", e.message);
            }
        }
    }
}
