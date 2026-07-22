/* unit.vala
 *
 * Unit tests for VLS utility functions, using GLib.Test.
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

using Vls.Util;
using Gee;
using Json;

class TestSerializable : GLib.Object, Serializable {
    public string name { get; set; }
    public int value { get; set; }
}

void test_compare_versions () {
    assert (compare_versions ("1.2.3", "1.2.4") < 0);
    assert (compare_versions ("1.2.4", "1.2.3") > 0);
    assert (compare_versions ("1.2.3", "1.2.3") == 0);
    assert (compare_versions ("1.0", "1.0.0") < 0);
    assert (compare_versions ("2.0", "1.9.9") > 0);
}

void test_get_string_pos () {
    size_t pos = Vls.Foundation.get_string_pos ("line0\nline1\nline2", 1, 2);
    assert (pos == 8);
    pos = Vls.Foundation.get_string_pos ("abc", 0, 0);
    assert (pos == 0);
}

void test_count_chars_in_string () {
    int last = -1;
    assert (count_chars_in_string ("a.b.c", '.', out last) == 2);
    assert (last == 3);
    assert (count_chars_in_string ("no dots", '.', out last) == 0);
}

void test_get_arguments_from_command_str () {
    try {
        var args = get_arguments_from_command_str ("vala --pkg gtk4 'my file.vala'");
        assert (args.length == 4);
        assert (args[0] == "vala");
        assert (args[1] == "--pkg");
        assert (args[2] == "gtk4");
        assert (args[3] == "my file.vala");
    } catch (RegexError e) {
        assert_not_reached ();
    }
}

void test_is_newline () {
    assert (is_newline ('\n'));
    assert (is_newline ('\r'));
    assert (!is_newline ('a'));
}

void test_arg_is_vala_file () {
    assert (arg_is_vala_file ("foo.vala"));
    assert (arg_is_vala_file ("foo.vapi"));
    assert (arg_is_vala_file ("foo.gir"));
    assert (!arg_is_vala_file ("foo.c"));
    assert (!arg_is_vala_file ("foo.txt"));
}

void test_serialize_roundtrip () {
    var obj = new TestSerializable ();
    obj.name = "hello";
    obj.value = 42;
    try {
        Variant v = object_to_variant (obj);
        var back = parse_variant<TestSerializable> (v);
        assert (back.name == "hello");
        assert (back.value == 42);
    } catch (Error e) {
        assert_not_reached ();
    }
}

void test_find_name_in_text () {
    assert (find_name_in_text ("foo bar", "foo") == 0);
    assert (find_name_in_text ("call foo()", "foo") == 5);
    assert (find_name_in_text ("foobar", "foo") == -1);
    assert (find_name_in_text ("_foobar", "foo") == -1);
    assert (find_name_in_text ("foo_bar", "foo") == -1);
    assert (find_name_in_text ("foo_bar", "foo_bar") == 0);
    assert (find_name_in_text ("foo foo", "foo") == 0);
    assert (find_name_in_text ("bar baz", "foo") == -1);
}

 void test_line_byte_length () {
    assert (Vls.Foundation.line_byte_length ("hello\nworld", 0) == 5);
    assert (Vls.Foundation.line_byte_length ("hello\nworld", 1) == 5);
    assert (Vls.Foundation.line_byte_length ("single", 0) == 6);
    assert (Vls.Foundation.line_byte_length ("\n\n", 0) == 0);
    assert (Vls.Foundation.line_byte_length ("\n\n", 1) == 0);
    assert (Vls.Foundation.line_byte_length ("abc\n\ndef", 1) == 0);
}

void test_textdocument_byte_offset () {
    var ctx = new Vala.CodeContext ();
    var file = File.new_for_uri ("file:///vls_test_td_unit.vala");
    Vls.TextDocument doc;
    try {
        doc = new Vls.TextDocument (ctx, file, "line0\nline1\nline2");
    } catch (GLib.FileError e) {
        assert_not_reached ();
    }
    assert (doc.byte_offset (0, 0) == 0);
    assert (doc.byte_offset (1, 2) == 8);
    assert (doc.byte_offset (3, 5) == 17);
    // cache invalidates on content change
    doc.content = "abc\nxyz";
    assert (doc.byte_offset (1, 0) == 4);
}


void test_is_decl_keyword () {
    assert (is_decl_keyword ("public"));
    assert (is_decl_keyword ("class"));
    assert (is_decl_keyword ("namespace"));
    assert (is_decl_keyword ("foreach"));
    assert (is_decl_keyword ("yield"));
    assert (is_decl_keyword ("owned"));
    assert (is_decl_keyword ("unowned"));
    assert (is_decl_keyword ("weak"));
    assert (is_decl_keyword ("get"));
    assert (is_decl_keyword ("set"));
    assert (!is_decl_keyword ("void"));
    assert (!is_decl_keyword ("var"));
    assert (!is_decl_keyword ("int"));
    assert (!is_decl_keyword ("string"));
    assert (!is_decl_keyword ("true"));
    assert (!is_decl_keyword ("false"));
    assert (!is_decl_keyword ("null"));
    assert (!is_decl_keyword ("this"));
    assert (!is_decl_keyword ("base"));
    assert (!is_decl_keyword ("as"));
    assert (!is_decl_keyword ("is"));
    assert (!is_decl_keyword ("sizeof"));
    assert (!is_decl_keyword ("typeof"));
    assert (!is_decl_keyword ("foo"));
    assert (!is_decl_keyword (""));
}

void test_delta_encode () {
    var tokens = new Gee.ArrayList<Vls.SemanticToken> ();
    var result = delta_encode (tokens);
    assert (result.size == 0);

    var t1 = new Vls.SemanticToken ();
    t1.line = 0; t1.character = 0; t1.length = 3; t1.token_type = 1; t1.modifiers = 0;
    tokens.add (t1);
    result = delta_encode (tokens);
    assert (result.size == 5);
    assert (result[0] == 0);
    assert (result[1] == 0);
    assert (result[2] == 3);
    assert (result[3] == 1);
    assert (result[4] == 0);

    var t2 = new Vls.SemanticToken ();
    t2.line = 0; t2.character = 5; t2.length = 4; t2.token_type = 2; t2.modifiers = 0;
    tokens.add (t2);
    result = delta_encode (tokens);
    assert (result.size == 10);
    assert (result[5] == 0);
    assert (result[6] == 5);
    assert (result[7] == 4);
    assert (result[8] == 2);
    assert (result[9] == 0);

    var t3 = new Vls.SemanticToken ();
    t3.line = 1; t3.character = 2; t3.length = 5; t3.token_type = 3; t3.modifiers = 1;
    tokens.add (t3);
    result = delta_encode (tokens);
    assert (result.size == 15);
    assert (result[10] == 1);
    assert (result[11] == 2);
    assert (result[12] == 5);
    assert (result[13] == 3);
    assert (result[14] == 1);
}

void test_project_path () {
    var cwd = Environment.get_current_dir ();

    // Path inside the project — replaced with $PROJECT
    var inside = GLib.Path.build_filename (cwd, "src", "file.vala");
    assert (project_path (inside) == "$PROJECT/src/file.vala");

    // Path equal to project root
    assert (project_path (cwd) == "$PROJECT");

    // Path outside the project — unchanged
    assert (project_path ("/nonexistent/__vls_test__") == "/nonexistent/__vls_test__");

    // Empty string — unchanged
    assert (project_path ("") == "");
}

void test_project_uri () {
    var cwd = Environment.get_current_dir ();

    // file:// URI inside the project
    var uri = "file://" + cwd + "/src/file.vala";
    assert (project_uri (uri) == "$PROJECT/src/file.vala");

    // file:// URI outside the project — returns path without $PROJECT
    assert (project_uri ("file:///nonexistent/__vls_test__.vala")
            == "/nonexistent/__vls_test__.vala");

    // Non-file URI — returns as-is
    assert (project_uri ("untitled:Untitled-1") == "untitled:Untitled-1");

    // Percent-encoded path inside the project
    var encoded = "file://" + cwd + "/src/file%20name.vala";
    assert (project_uri (encoded) == "$PROJECT/src/file name.vala");
}

void test_scan_templates_empty () {
    var result = Vls.Foundation.scan_templates ("");
    assert (result.size == 0);
}

void test_scan_templates_no_templates () {
    var result = Vls.Foundation.scan_templates ("int x = 5;");
    assert (result.size == 0);
}

void test_scan_templates_simple () {
    var result = Vls.Foundation.scan_templates ("@\"hello\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.start == 0);
    assert (t.end == 8); // @"hello" = 8 bytes
    assert (t.interpolations.size == 0);
}

void test_scan_templates_single_interpolation () {
    var result = Vls.Foundation.scan_templates ("@\"hello $(name)\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.start == 0);
    assert (t.end == 16); // @"hello $(name)" = 16 bytes
    assert (t.interpolations.size == 1);
    assert (t.interpolations[0].start == 8);  // $( starts at 8
    assert (t.interpolations[0].end == 15);   // ) at 14, so end=15
}

void test_scan_templates_shorthand_interpolation () {
    var result = Vls.Foundation.scan_templates ("@\"$name\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.interpolations.size == 1);
    assert (t.interpolations[0].start == 2);  // $ starts at 2
    assert (t.interpolations[0].end == 7);    // name = 4 chars, so end=7
}

void test_scan_templates_multiple_interpolations () {
    var result = Vls.Foundation.scan_templates ("@\"$(a) and $(b)\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.interpolations.size == 2);
    assert (t.interpolations[0].start == 2);
    assert (t.interpolations[0].end == 6);
    assert (t.interpolations[1].start == 11);
    assert (t.interpolations[1].end == 15);
}

void test_scan_templates_escaped_quote () {
    var result = Vls.Foundation.scan_templates ("@\"hello \\\" world\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.interpolations.size == 0);
}

void test_scan_templates_empty_template () {
    var result = Vls.Foundation.scan_templates ("@\"\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.start == 0);
    assert (t.end == 3);
    assert (t.interpolations.size == 0);
}

void test_scan_templates_interpolation_only () {
    var result = Vls.Foundation.scan_templates ("@\"$(x)\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.interpolations.size == 1);
    assert (t.interpolations[0].start == 2);
    assert (t.interpolations[0].end == 6);
}

void test_scan_templates_nested_parens () {
    var result = Vls.Foundation.scan_templates ("@\"$(foo(1))\"");
    assert (result.size == 1);
    var t = result[0];
    assert (t.interpolations.size == 1);
    assert (t.interpolations[0].start == 2);
    assert (t.interpolations[0].end == 11); // $(foo(1)) = 11 bytes from $
}

void test_scan_templates_multiple_templates () {
    var result = Vls.Foundation.scan_templates ("@\"a\" + @\"$(b)\"");
    assert (result.size == 2);
    assert (result[0].start == 0);
    assert (result[0].end == 4);  // @"a" = 4 bytes
    assert (result[0].interpolations.size == 0);
    assert (result[1].start == 7);
    assert (result[1].end == 14); // @"$(b)" = 7 bytes (7..14)
    assert (result[1].interpolations.size == 1);
}

void test_response_builder_full () {
    var data = new ArrayList<uint> ();
    data.add (10);
    data.add (20);
    data.add (30);
    var result = Vls.Foundation.SemanticTokensResponseBuilder.build_full ("abc", data);
    assert (result != null);
    assert (result.get_type ().equal (new VariantType ("a{sv}")));
    // Verify resultId
    var resultId = result.lookup_value ("resultId", null);
    assert (resultId != null);
    assert (resultId.get_string () == "abc");
    // Verify data is present
    var data_var = result.lookup_value ("data", null);
    assert (data_var != null);
}

void test_response_builder_delta () {
    var old_data = new ArrayList<uint> ();
    old_data.add (1);
    old_data.add (2);
    old_data.add (3);
    old_data.add (4);
    var new_data = new ArrayList<uint> ();
    new_data.add (10);
    new_data.add (20);
    var result = Vls.Foundation.SemanticTokensResponseBuilder.build_delta ("def", old_data, new_data);
    assert (result != null);
    assert (result.get_type ().equal (new VariantType ("a{sv}")));
    // Verify resultId
    var resultId = result.lookup_value ("resultId", null);
    assert (resultId != null);
    assert (resultId.get_string () == "def");
    // Verify edits is present and well-formed
    var edits = result.lookup_value ("edits", null);
    assert (edits != null);
    assert (edits.get_type ().equal (new VariantType ("aa{sv}")));
}

void test_response_builder_delta_crash_regression () {
    // Reproduce the delta crash: building a delta response must not abort.
    // The bug was using add("a{sv}", ...) instead of add_value() for the
    // child edit variant, which leaves the builder in an inconsistent state.
    var old_data = new ArrayList<uint> ();
    old_data.add (100);
    old_data.add (200);
    var new_data = new ArrayList<uint> ();
    new_data.add (50);
    new_data.add (60);
    new_data.add (70);
    // This must not crash — the old code would abort here.
    var result = Vls.Foundation.SemanticTokensResponseBuilder.build_delta ("crash-test", old_data, new_data);
    assert (result != null);
    // Verify deleteCount equals old_data.size
    var edits = result.lookup_value ("edits", null);
    assert (edits != null);
    var edit0 = edits.get_child_value (0);
    var deleteCount = edit0.lookup_value ("deleteCount", null);
    assert (deleteCount != null);
    assert (deleteCount.get_int32 () == 2);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/vls/util/compare_versions", test_compare_versions);
    Test.add_func ("/vls/util/get_string_pos", test_get_string_pos);
    Test.add_func ("/vls/util/count_chars_in_string", test_count_chars_in_string);
    Test.add_func ("/vls/util/get_arguments_from_command_str", test_get_arguments_from_command_str);
    Test.add_func ("/vls/util/is_newline", test_is_newline);
    Test.add_func ("/vls/util/arg_is_vala_file", test_arg_is_vala_file);
    Test.add_func ("/vls/util/serialize_roundtrip", test_serialize_roundtrip);
    Test.add_func ("/vls/util/find_name_in_text", test_find_name_in_text);
    Test.add_func ("/vls/util/line_byte_length", test_line_byte_length);
    Test.add_func ("/vls/util/is_decl_keyword", test_is_decl_keyword);
    Test.add_func ("/vls/util/delta_encode", test_delta_encode);
    Test.add_func ("/vls/util/project_path", test_project_path);
    Test.add_func ("/vls/util/project_uri", test_project_uri);
    Test.add_func ("/vls/foundation/scan_templates/empty", test_scan_templates_empty);
    Test.add_func ("/vls/foundation/scan_templates/no_templates", test_scan_templates_no_templates);
    Test.add_func ("/vls/foundation/scan_templates/simple", test_scan_templates_simple);
    Test.add_func ("/vls/foundation/scan_templates/single_interpolation", test_scan_templates_single_interpolation);
    Test.add_func ("/vls/foundation/scan_templates/shorthand_interpolation", test_scan_templates_shorthand_interpolation);
    Test.add_func ("/vls/foundation/scan_templates/multiple_interpolations", test_scan_templates_multiple_interpolations);
    Test.add_func ("/vls/foundation/scan_templates/escaped_quote", test_scan_templates_escaped_quote);
    Test.add_func ("/vls/foundation/scan_templates/empty_template", test_scan_templates_empty_template);
    Test.add_func ("/vls/foundation/scan_templates/interpolation_only", test_scan_templates_interpolation_only);
    Test.add_func ("/vls/foundation/scan_templates/nested_parens", test_scan_templates_nested_parens);
    Test.add_func ("/vls/foundation/scan_templates/multiple_templates", test_scan_templates_multiple_templates);
    Test.add_func ("/vls/foundation/response_builder/full", test_response_builder_full);
    Test.add_func ("/vls/foundation/response_builder/delta", test_response_builder_delta);
    Test.add_func ("/vls/foundation/response_builder/delta_crash_regression", test_response_builder_delta_crash_regression);
    Test.add_func ("/vls/util/textdocument_byte_offset", test_textdocument_byte_offset);
    Vls.Util.set_project_root (Environment.get_current_dir ());
    return Test.run ();
}
