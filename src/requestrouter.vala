/* requestrouter.vala
 *
 * Copyright 2024 Vala Language Server Contributors
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;

/**
 * Routes incoming LSP requests and notifications to the appropriate handlers.
 */
class Vls.RequestRouter : Object {
    private Server _server;

    public RequestRouter (Server server) {
        _server = server;
    }

    public bool handle_call (Jsonrpc.Client client, string method, Variant id, Variant parameters) {
        // Register per-request cancellable for fine-grained cancellation.
        _server.request_cancellables[new Request (id)] = new Cancellable ();

        switch (method) {
            case "initialize":
                _server.initialize (client, method, id, parameters);
                break;

            case "shutdown":
                _server.shutdown ();
                Server.reply_null (id, client, method);
                break;

            case "textDocument/definition":
                Navigation.goto_definition (_server, client, method, id, parameters);
                break;

            case "textDocument/documentSymbol":
                _server.dispatch_document_symbol (client, method, id, parameters);
                break;

            case "textDocument/completion":
                _server.show_completion (client, method, id, parameters);
                break;

            case "textDocument/signatureHelp":
                _server.show_signature_help (client, method, id, parameters);
                break;

            case "textDocument/hover":
                HoverHandler.hover (_server, client, method, id, parameters);
                break;

            case "textDocument/formatting":
            case "textDocument/rangeFormatting":
                _server.format (client, method, id, parameters);
                break;

            case "textDocument/codeAction":
                _server.code_action (client, method, id, parameters);
                break;

            case "textDocument/references":
            case "textDocument/documentHighlight":
                Navigation.show_references (_server, client, method, id, parameters);
                break;

            case "textDocument/implementation":
                Navigation.show_implementations (_server, client, method, id, parameters);
                break;

            case "workspace/symbol":
                _server.dispatch_workspace_symbol (client, method, id, parameters);
                break;

            case "textDocument/rename":
                _server.dispatch_rename (client, method, id, parameters);
                break;

            case "textDocument/prepareRename":
                _server.dispatch_prepare_rename (client, method, id, parameters);
                break;

            case "textDocument/codeLens":
                _server.dispatch_code_lens (client, method, id, parameters);
                break;

            case "textDocument/prepareCallHierarchy":
                _server.dispatch_prepare_call_hierarchy (client, method, id, parameters);
                break;

            case "callHierarchy/incomingCalls":
                _server.dispatch_call_hierarchy_incoming_calls (client, method, id, parameters);
                break;

            case "callHierarchy/outgoingCalls":
                _server.dispatch_call_hierarchy_outgoing_calls (client, method, id, parameters);
                break;

            case "textDocument/inlayHint":
                _server.dispatch_inlay_hint (client, method, id, parameters);
                break;

            case "textDocument/prepareTypeHierarchy":
                _server.dispatch_prepare_type_hierarchy (client, method, id, parameters);
                break;

            case "typeHierarchy/supertypes":
                _server.dispatch_show_type_hierarchy (client, method, id, parameters, true);
                break;

            case "typeHierarchy/subtypes":
                _server.dispatch_show_type_hierarchy (client, method, id, parameters, false);
                break;

            case "textDocument/semanticTokens/full":
                _server.dispatch_semantic_tokens_full (client, method, id, parameters);
                break;

            case "textDocument/semanticTokens/full/delta":
                _server.dispatch_semantic_tokens_delta (client, method, id, parameters);
                break;

            case "textDocument/semanticTokens/range":
                _server.dispatch_semantic_tokens_range (client, method, id, parameters);
                break;

            default:
                warning ("unhandled call `%s'", method);
                return false;
        }
        return true;
    }

    public void notification (Jsonrpc.Client client, string method, Variant parameters) {
        switch (method) {
            case "exit":
                _server.exit ();
                break;

            case "$/cancelRequest":
                _server.cancel_request (client, parameters);
                break;

            case "$/setTrace":
                string? trace_value = null;
                parameters.lookup ("value", "s", out trace_value);
                _server.trace = Lsp.TraceValue.parse (trace_value);
                break;

            case "initialized":
                break;

            case "textDocument/didOpen":
                _server.text_document_did_open (client, parameters);
                break;

            case "textDocument/didSave":
                _server.text_document_did_save (client, parameters);
                break;

            case "textDocument/didClose":
                _server.text_document_did_close (client, parameters);
                break;

            case "textDocument/didChange":
                _server.text_document_did_change (client, parameters);
                break;

            default:
                warning ("unhandled notification `%s'", method);
                break;
        }
    }
}
