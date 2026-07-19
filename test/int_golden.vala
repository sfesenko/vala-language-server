/* int_golden.vala
 *
 * Golden integration tests: a fixture + an expected JSON reply, compared with
 * Helpers.assert_json_equals. One subdirectory under test/golden/ per feature.
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

using GLib;
using Jsonrpc;

// Locate <repo>/test/golden by walking up until a directory that
// actually contains test/golden is found (the build dir also has a
// generated src/ subtree, so we key on test/golden itself).
string golden_dir () {
    var d = Environment.get_current_dir ();
    for (int i = 0; i < 6; i++) {
        var cand = GLib.Path.build_filename (d, "test", "golden");
        if (FileUtils.test (cand, FileTest.IS_DIR))
            return cand;
        string parent = GLib.Path.get_dirname (d);
        if (parent == d)
            break;
        d = parent;
    }
    return GLib.Path.build_filename (Environment.get_current_dir (), "test", "golden");
}

void test_golden_document_symbol () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/documentSymbol", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "document_symbol", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_goto_definition () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/definition", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "goto_definition", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_references () {
    var s = setup_session (REFERENCES_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/references", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17)),
        context: h.build_dict (includeDeclaration: new Variant.boolean (true))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "references", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_document_highlight () {
    var s = setup_session (REFERENCES_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/documentHighlight", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "document_highlight", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_implementation () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/implementation", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (25))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "implementation", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_hover () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/hover", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "hover", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_rename () {
    var s = setup_session (REFERENCES_FIXTURE, "rename.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/rename", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17)),
        newName: new Variant.string ("renamed")
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "rename", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_prepare_rename () {
    var s = setup_session (REFERENCES_FIXTURE, "rename.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/prepareRename", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (17))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "prepare_rename", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_completion () {
    var s = setup_session (COMPLETION_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/completion", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (11))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "completion", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_semantic_tokens_full () {
    var s = setup_session (SEMANTIC_TOKENS_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "semantic_tokens_full", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_semantic_tokens_range () {
    var s = setup_session (SEMANTIC_TOKENS_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/range", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        range: h.build_dict (
            start: h.build_dict (line: new Variant.int32 (0), character: new Variant.int32 (0)),
            end: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (0))
        )
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "semantic_tokens_range", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_semantic_tokens_full_delta () {
    var s = setup_session (SEMANTIC_TOKENS_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full/delta", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        previousResultId: new Variant.string ("0")
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "semantic_tokens_full_delta", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_signature_help () {
    var s = setup_session (SIGNATURE_HELP_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/signatureHelp", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (5), character: new Variant.int32 (13))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "signature_help", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_formatting () {
    if (Environment.find_program_in_path ("uncrustify") == null) {
        Test.skip ();
        return;
    }
    var s = setup_session (FORMAT_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/formatting", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        options: h.build_dict (tabSize: new Variant.int32 (4), insertSpaces: new Variant.boolean (true))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "formatting", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_workspace_symbol () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "workspace/symbol", h.build_dict (
        query: new Variant.string ("Foo")
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "workspace_symbol", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_inlay_hint () {
    var s = setup_session (INLAY_HINT_FIXTURE, "inlayhint.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/inlayHint", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        range: h.build_dict (
            start: h.build_dict (line: new Variant.int32 (0), character: new Variant.int32 (0)),
            end: h.build_dict (line: new Variant.int32 (6), character: new Variant.int32 (0))
        )
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "inlay_hint", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_code_lens () {
    var s = setup_session (CODELENS_FIXTURE, "codelens.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/codeLens", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "code_lens", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_code_action () {
    var s = setup_session (CODEACTION_FIXTURE, "codeaction.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/codeAction", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        range: h.build_dict (
            start: h.build_dict (line: new Variant.int32 (9), character: new Variant.int32 (16)),
            end: h.build_dict (line: new Variant.int32 (9), character: new Variant.int32 (16))
        ),
        context: h.build_dict (diagnostics: new Variant.array (VariantType.VARDICT, {}))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "code_action", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_prepare_type_hierarchy () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/prepareTypeHierarchy", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (3), character: new Variant.int32 (25))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "prepare_type_hierarchy", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_prepare_call_hierarchy () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/prepareCallHierarchy", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (25))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "prepare_call_hierarchy", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_range_formatting () {
    if (Environment.find_program_in_path ("uncrustify") == null) {
        Test.skip ();
        return;
    }
    var s = setup_session (FORMAT_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/rangeFormatting", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        range: h.build_dict (
            start: h.build_dict (line: new Variant.int32 (0), character: new Variant.int32 (0)),
            end: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (1))
        ),
        options: h.build_dict (tabSize: new Variant.int32 (4), insertSpaces: new Variant.boolean (true))
    ));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "range_formatting", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

// Continuation golden tests: chain a `prepare*` call with its `*`-fetch
// counterpart. The `item` passed to the continuation is taken verbatim from
// the prepare reply, mirroring the two-step protocol flow a real client uses.

void test_golden_type_hierarchy_supertypes () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? prepare = Helpers.sync_call (s.client, "textDocument/prepareTypeHierarchy", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (8))
    ));
    assert (prepare != null);
    var item = prepare.get_child_value (0);
    Variant? res = Helpers.sync_call (s.client, "typeHierarchy/supertypes", h.build_dict (item: item));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "type_hierarchy_supertypes", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_type_hierarchy_subtypes () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? prepare = Helpers.sync_call (s.client, "textDocument/prepareTypeHierarchy", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (1), character: new Variant.int32 (13))
    ));
    assert (prepare != null);
    var item = prepare.get_child_value (0);
    Variant? res = Helpers.sync_call (s.client, "typeHierarchy/subtypes", h.build_dict (item: item));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "type_hierarchy_subtypes", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_call_hierarchy_incoming () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? prepare = Helpers.sync_call (s.client, "textDocument/prepareCallHierarchy", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (8))
    ));
    assert (prepare != null);
    var item = prepare.get_child_value (0);
    Variant? res = Helpers.sync_call (s.client, "callHierarchy/incomingCalls", h.build_dict (item: item));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "call_hierarchy_incoming", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}

void test_golden_call_hierarchy_outgoing () {
    var s = setup_session (HIERARCHY_FIXTURE, "hierarchy.vala");
    var h = new Helpers ();
    Variant? prepare = Helpers.sync_call (s.client, "textDocument/prepareCallHierarchy", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        position: h.build_dict (line: new Variant.int32 (4), character: new Variant.int32 (25))
    ));
    assert (prepare != null);
    var item = prepare.get_child_value (0);
    Variant? res = Helpers.sync_call (s.client, "callHierarchy/outgoingCalls", h.build_dict (item: item));
    assert (res != null);
    var path = GLib.Path.build_filename (golden_dir (), "call_hierarchy_outgoing", "expected.json");
    Helpers.assert_json_equals (res, path);
    teardown_session (s);
}
