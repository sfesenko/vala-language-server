/* int_runner.vala
 *
 * Integration test runner — registers all int_ tests and runs them.
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

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/int/publish_diagnostics", test_publish_diagnostics);
    Test.add_func ("/int/non_native_root_survives", test_non_native_root_survives);
    Test.add_func ("/int/initialize_capabilities", test_initialize_capabilities);
    Test.add_func ("/int/document_symbol", test_document_symbol);
    Test.add_func ("/int/hover", test_hover);
    Test.add_func ("/int/goto_definition", test_goto_definition);
    Test.add_func ("/int/range_formatting", test_range_formatting);
    Test.add_func ("/int/completion", test_completion);
    Test.add_func ("/int/semantic_tokens_full", test_semantic_tokens_full);
    Test.add_func ("/int/semantic_tokens_coverage", test_semantic_tokens_coverage);
    Test.add_func ("/int/semantic_tokens_range", test_semantic_tokens_range);
    Test.add_func ("/int/semantic_tokens_template_string", test_semantic_tokens_template_string);
    Test.add_func ("/int/semantic_tokens_delta", test_semantic_tokens_delta);
    Test.add_func ("/int/references", test_references);
    Test.add_func ("/int/document_highlight", test_document_highlight);
    Test.add_func ("/int/inlay_hint", test_inlay_hint);
    Test.add_func ("/int/workspace_symbol", test_workspace_symbol);
    Test.add_func ("/int/formatting", test_formatting);
    Test.add_func ("/int/implementation", test_implementation);
    Test.add_func ("/int/log_uses_project_path", test_log_uses_project_path);
    Test.add_func ("/int/golden/document_symbol", test_golden_document_symbol);
    Test.add_func ("/int/golden/goto_definition", test_golden_goto_definition);
    Test.add_func ("/int/regression/adversarial_smoke_template_string", test_adversarial_smoke_template_string);
    Test.add_func ("/int/regression/adversarial_smoke_single_dollar", test_adversarial_smoke_single_dollar);
    Test.add_func ("/int/regression/adversarial_smoke_inverted_ref", test_adversarial_smoke_inverted_ref);
    return Test.run ();
}
