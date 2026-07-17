/* int_semantictokens.vala
 *
 * Semantic tokens integration tests.
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
 * along with this program.  If not see <http://www.gnu.org/licenses/>.
 */

using GLib;
using Jsonrpc;

struct DecodedToken {
    uint line;
    uint length;
    uint token_type;
}

struct FullToken {
    uint line;
    uint character;
    uint length;
    uint token_type;
}

Gee.List<DecodedToken?> decode_tokens (Variant data) {
    var result = new Gee.ArrayList<DecodedToken?> ();
    Json.Node json_node = Json.gvariant_serialize (data);
    var json_array = json_node.get_array ();
    uint n = json_array.get_length ();
    uint prev_line = 0;
    for (uint i = 0; i + 4 < n; i += 5) {
        uint delta_line = (uint) json_array.get_int_element (i);
        uint len = (uint) json_array.get_int_element (i + 2);
        uint tok_type = (uint) json_array.get_int_element (i + 3);
        prev_line += delta_line;
        DecodedToken tok = { prev_line, len, tok_type };
        result.add (tok);
    }
    return result;
}

bool has_token (Gee.List<DecodedToken?> tokens, uint line, uint token_type, uint length) {
    foreach (var t in tokens)
        if (t.line == line && t.token_type == token_type && t.length == length)
            return true;
    return false;
}

bool has_token_on_line (Gee.List<DecodedToken?> tokens, uint line, uint token_type) {
    foreach (var t in tokens)
        if (t.line == line && t.token_type == token_type)
            return true;
    return false;
}

bool has_token_on_line_full (Gee.List<FullToken?> tokens, uint line, uint token_type) {
    foreach (var t in tokens)
        if (t.line == line && t.token_type == token_type)
            return true;
    return false;
}

Gee.List<FullToken?> decode_tokens_full (Variant data) {
    var result = new Gee.ArrayList<FullToken?> ();
    Json.Node json_node = Json.gvariant_serialize (data);
    var json_array = json_node.get_array ();
    uint n = json_array.get_length ();
    uint prev_line = 0;
    uint prev_char = 0;
    for (uint i = 0; i + 4 < n; i += 5) {
        uint delta_line = (uint) json_array.get_int_element (i);
        uint delta_char = (uint) json_array.get_int_element (i + 1);
        uint len = (uint) json_array.get_int_element (i + 2);
        uint tok_type = (uint) json_array.get_int_element (i + 3);
        prev_line += delta_line;
        prev_char = (delta_line == 0) ? prev_char + delta_char : delta_char;
        FullToken tok = { prev_line, prev_char, len, tok_type };
        result.add (tok);
    }
    return result;
}

void assert_no_overlap (Gee.List<FullToken?> tokens) {
    FullToken? prev = null;
    foreach (var t in tokens) {
        if (prev != null && t.line == prev.line)
            assert (t.character >= prev.character + prev.length);
        prev = t;
    }
}

void test_semantic_tokens_full () {
    var s = setup_session (SYMBOL_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    assert (data.n_children () > 0);
    teardown_session (s);
}

void test_semantic_tokens_coverage () {
    var s = setup_session (SEMANTIC_TOKENS_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));
    var tokens = decode_tokens (data);
    assert (tokens.size > 0);

    const uint NAMESPACE = 0;
    const uint CLASS = 1;
    const uint ENUM = 2;
    const uint INTERFACE = 3;
    const uint STRUCT = 4;
    const uint TYPE_PARAMETER = 5;
    const uint TYPE = 6;
    const uint PARAMETER = 7;
    const uint VARIABLE = 8;
    const uint PROPERTY = 9;
    const uint ENUM_MEMBER = 10;
    const uint EVENT = 11;
    const uint FUNCTION = 12;
    const uint METHOD = 13;
    const uint KEYWORD = 14;
    const uint STRING = 15;
    const uint NUMBER = 16;

    assert (has_token (tokens, 0, KEYWORD, 9));
    assert (has_token (tokens, 0, NAMESPACE, 2));

    assert (has_token (tokens, 1, KEYWORD, 6));
    assert (has_token (tokens, 1, KEYWORD, 8));
    assert (has_token (tokens, 1, KEYWORD, 5));
    assert (has_token (tokens, 1, CLASS, 4));

    assert (has_token (tokens, 2, KEYWORD, 6));
    assert (has_token (tokens, 2, KEYWORD, 8));
    assert (has_token (tokens, 2, TYPE, 4));
    assert (has_token (tokens, 2, METHOD, 10));

    assert (has_token (tokens, 3, KEYWORD, 6));
    assert (has_token (tokens, 3, KEYWORD, 7));
    assert (has_token (tokens, 3, TYPE, 4));
    assert (has_token (tokens, 3, METHOD, 10));

    assert (has_token (tokens, 5, KEYWORD, 6));
    assert (has_token (tokens, 5, KEYWORD, 5));
    assert (has_token (tokens, 5, CLASS, 3));
    assert (has_token (tokens, 5, TYPE_PARAMETER, 1));

    assert (has_token (tokens, 6, KEYWORD, 6));
    assert (has_token (tokens, 6, METHOD, 3));

    assert (has_token_on_line (tokens, 7, METHOD));

    assert (has_token (tokens, 9, KEYWORD, 6));
    assert (has_token (tokens, 9, TYPE, 4));
    assert (has_token (tokens, 9, METHOD, 5));

    assert (has_token (tokens, 10, KEYWORD, 7));
    assert (has_token (tokens, 10, TYPE, 4));
    assert (has_token (tokens, 10, METHOD, 5));

    assert (has_token (tokens, 11, KEYWORD, 9));
    assert (has_token (tokens, 11, TYPE, 4));
    assert (has_token (tokens, 11, METHOD, 5));

    assert (has_token (tokens, 12, KEYWORD, 8));
    assert (has_token (tokens, 12, TYPE, 4));
    assert (has_token (tokens, 12, METHOD, 5));

    assert (has_token (tokens, 13, KEYWORD, 6));
    assert (has_token (tokens, 13, KEYWORD, 6));
    assert (has_token (tokens, 13, TYPE, 4));
    assert (has_token (tokens, 13, METHOD, 6));

    assert (has_token (tokens, 14, KEYWORD, 6));
    assert (has_token (tokens, 14, KEYWORD, 8));
    assert (has_token (tokens, 14, TYPE, 4));
    assert (has_token (tokens, 14, METHOD, 10));

    assert (has_token (tokens, 15, KEYWORD, 6));
    assert (has_token (tokens, 15, KEYWORD, 8));
    assert (has_token (tokens, 15, TYPE, 4));
    assert (has_token (tokens, 15, METHOD, 10));

    assert (has_token (tokens, 16, KEYWORD, 6));
    assert (has_token (tokens, 16, KEYWORD, 5));
    assert (has_token (tokens, 16, TYPE, 4));
    assert (has_token (tokens, 16, FUNCTION, 7));

    assert (has_token (tokens, 17, KEYWORD, 6));
    assert (has_token (tokens, 17, TYPE, 3));
    assert (has_token (tokens, 17, PROPERTY, 4));

    assert (has_token (tokens, 18, KEYWORD, 6));
    assert (has_token (tokens, 18, KEYWORD, 6));
    assert (has_token (tokens, 18, TYPE, 3));
    assert (has_token (tokens, 18, PROPERTY, 5));

    assert (has_token (tokens, 19, KEYWORD, 6));
    assert (has_token (tokens, 19, KEYWORD, 7));
    assert (has_token (tokens, 19, TYPE, 3));
    assert (has_token (tokens, 19, PROPERTY, 5));

    assert (has_token (tokens, 20, KEYWORD, 6));
    assert (has_token (tokens, 20, KEYWORD, 8));
    assert (has_token (tokens, 20, TYPE, 3));
    assert (has_token (tokens, 20, PROPERTY, 6));

    assert (has_token (tokens, 21, KEYWORD, 6));
    assert (has_token (tokens, 21, TYPE, 3));
    assert (has_token (tokens, 21, PROPERTY, 5));

    assert (has_token (tokens, 22, KEYWORD, 6));
    assert (has_token (tokens, 22, KEYWORD, 6));
    assert (has_token (tokens, 22, TYPE, 3));
    assert (has_token (tokens, 22, PROPERTY, 6));

    assert (has_token (tokens, 23, KEYWORD, 6));
    assert (has_token (tokens, 23, KEYWORD, 6));
    assert (has_token (tokens, 23, TYPE, 4));
    assert (has_token (tokens, 23, EVENT, 4));

    assert (has_token (tokens, 24, KEYWORD, 6));
    assert (has_token (tokens, 24, KEYWORD, 8));
    assert (has_token (tokens, 24, TYPE, 4));
    assert (has_token (tokens, 24, FUNCTION, 5));

    assert (has_token (tokens, 25, KEYWORD, 6));
    assert (has_token (tokens, 25, KEYWORD, 5));
    assert (has_token (tokens, 25, TYPE, 3));
    assert (has_token (tokens, 25, VARIABLE, 6));
    assert (has_token (tokens, 25, NUMBER, 2));

    assert (has_token (tokens, 26, KEYWORD, 6));
    assert (has_token (tokens, 26, KEYWORD, 5));
    assert (has_token (tokens, 26, TYPE, 6));
    assert (has_token (tokens, 26, VARIABLE, 4));
    assert (has_token (tokens, 26, STRING, 6));

    assert (has_token (tokens, 28, KEYWORD, 6));
    assert (has_token (tokens, 28, TYPE, 4));
    assert (has_token (tokens, 28, METHOD, 8));
    assert (has_token (tokens, 28, TYPE, 6));
    assert (has_token (tokens, 28, PARAMETER, 1));
    assert (has_token (tokens, 28, TYPE, 3));
    assert (has_token (tokens, 28, PARAMETER, 1));

    assert (has_token (tokens, 29, TYPE, 3));
    assert (has_token (tokens, 29, VARIABLE, 5));
    assert (has_token (tokens, 29, NUMBER, 2));

    assert (has_token (tokens, 30, TYPE, 6));
    assert (has_token (tokens, 30, VARIABLE, 3));
    assert (has_token (tokens, 30, STRING, 7));

    assert (has_token (tokens, 31, TYPE, 4));
    assert (has_token (tokens, 31, VARIABLE, 4));
    assert (has_token (tokens, 31, NUMBER, 4));

    assert (has_token (tokens, 32, TYPE, 6));
    assert (has_token (tokens, 32, VARIABLE, 2));
    assert (has_token (tokens, 32, NUMBER, 4));

    assert (has_token (tokens, 33, VARIABLE, 3));
    assert (has_token (tokens, 33, CLASS, 8));

    assert (has_token (tokens, 34, VARIABLE, 3));
    assert (has_token (tokens, 34, METHOD, 5));

    assert (has_token (tokens, 35, VARIABLE, 3));
    assert (has_token (tokens, 35, PROPERTY, 4));
    assert (has_token (tokens, 35, NUMBER, 1));

    assert (has_token (tokens, 36, VARIABLE, 1));
    assert (has_token (tokens, 36, VARIABLE, 3));
    assert (has_token (tokens, 36, PROPERTY, 5));

    assert (has_token (tokens, 37, VARIABLE, 1));
    assert (has_token (tokens, 37, TYPE, 4));

    assert (has_token (tokens, 38, VARIABLE, 1));
    assert (has_token (tokens, 38, VARIABLE, 3));

    assert (has_token (tokens, 39, VARIABLE, 4));
    assert (has_token (tokens, 39, VARIABLE, 1));

    assert (has_token (tokens, 40, VARIABLE, 3));
    assert (has_token (tokens, 40, STRING, 5));
    assert (has_token (tokens, 40, STRING, 5));

    assert (has_token (tokens, 42, KEYWORD, 6));
    assert (has_token (tokens, 42, TYPE, 4));
    assert (has_token_on_line (tokens, 42, METHOD));
    assert (has_token_on_line (tokens, 42, TYPE));

    assert (has_token (tokens, 43, VARIABLE, 2));
    assert (has_token (tokens, 43, STRING, 7));

    assert (has_token (tokens, 44, VARIABLE, 2));
    assert (has_token_on_line (tokens, 44, VARIABLE));

    assert (has_token (tokens, 45, VARIABLE, 7));

    assert (has_token (tokens, 46, METHOD, 13));

    assert (has_token_on_line (tokens, 47, PARAMETER));
    assert (has_token (tokens, 47, NUMBER, 1));

    assert (has_token (tokens, 49, KEYWORD, 6));
    assert (has_token (tokens, 49, TYPE, 4));
    assert (has_token_on_line (tokens, 49, METHOD));

    assert (has_token (tokens, 50, TYPE, 3));
    assert (has_token_on_line (tokens, 50, VARIABLE));
    assert (has_token (tokens, 50, NUMBER, 1));

    assert (has_token_on_line (tokens, 51, VARIABLE));
    assert (has_token_on_line (tokens, 51, VARIABLE));

    assert (has_token (tokens, 54, KEYWORD, 6));
    assert (has_token_on_line (tokens, 54, METHOD));

    assert (has_token_on_line (tokens, 55, PROPERTY));

    assert (has_token (tokens, 58, KEYWORD, 6));
    assert (has_token (tokens, 58, KEYWORD, 6));
    assert (has_token (tokens, 58, STRUCT, 8));

    assert (has_token (tokens, 59, KEYWORD, 6));
    assert (has_token (tokens, 59, TYPE, 3));
    assert (has_token (tokens, 59, PROPERTY, 1));

    assert (has_token (tokens, 60, KEYWORD, 6));
    assert (has_token (tokens, 60, TYPE, 4));
    assert (has_token (tokens, 60, METHOD, 6));

    assert (has_token (tokens, 62, KEYWORD, 6));
    assert (has_token (tokens, 62, KEYWORD, 4));
    assert (has_token (tokens, 62, ENUM, 6));

    assert (has_token (tokens, 63, ENUM_MEMBER, 5));
    assert (has_token (tokens, 64, ENUM_MEMBER, 5));

    assert (has_token (tokens, 66, KEYWORD, 6));
    assert (has_token (tokens, 66, KEYWORD, 9));
    assert (has_token (tokens, 66, INTERFACE, 11));

    assert (has_token (tokens, 67, KEYWORD, 6));
    assert (has_token (tokens, 67, KEYWORD, 8));
    assert (has_token (tokens, 67, TYPE, 4));
    assert (has_token (tokens, 67, METHOD, 5));

    teardown_session (s);
}

void test_semantic_tokens_delta () {
    var s = setup_session (TEMPLATE_STRING_FIXTURE);
    var h = new Helpers ();
    // First request a full result so the server stores a previousResultId.
    Variant? full = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (full != null);
    Variant? rid = full.lookup_value ("resultId", null);
    assert (rid != null);
    string result_id = rid.get_string ();

    // Now request a delta referencing the previous result. This used to crash
    // the server (invalid GVariant builder in reply_with_tokens).
    Variant? delta = Helpers.sync_call (s.client, "textDocument/semanticTokens/full/delta", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri)),
        previousResultId: new Variant.string (result_id)
    ));
    assert (delta != null);
    bool has_edits = delta.lookup_value ("edits", null) != null;
    bool has_data = delta.lookup_value ("data", null) != null;
    assert (has_edits || has_data);

    teardown_session (s);
}

void test_semantic_tokens_template_string () {
    var s = setup_session (TEMPLATE_STRING_FIXTURE);
    var h = new Helpers ();
    Variant? res = Helpers.sync_call (s.client, "textDocument/semanticTokens/full", h.build_dict (
        textDocument: h.build_dict (uri: new Variant.string (s.uri))
    ));
    assert (res != null);
    Variant? data = res.lookup_value ("data", null);
    assert (data != null);
    assert (data.is_of_type (VariantType.ARRAY));

    var tokens = decode_tokens_full (data);
    assert (tokens.size > 0);

    const uint STRING = 15;
    const uint PARAMETER = 7;

    // The literal segments of the template must be tokenized as STRING...
    assert (has_token_on_line_full (tokens, 2, STRING));
    // ...and the interpolated identifiers must NOT be swallowed by the string
    // token (they get their own, non-overlapping tokens).
    assert (has_token_on_line_full (tokens, 2, PARAMETER));
    // Tokens must never overlap (LSP requirement; violated before the fix).
    assert_no_overlap (tokens);

    teardown_session (s);
}
