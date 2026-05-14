import ast
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "wfst_model_run.py"


def _function_node(tree, name):
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"Function not found: {name}")


def _direct_log_phase_calls(function_name):
    tree = ast.parse(SCRIPT_PATH.read_text(encoding="utf-8"))
    function = _function_node(tree, function_name)
    calls = []
    for node in ast.walk(function):
        if not isinstance(node, ast.Call):
            continue
        if not isinstance(node.func, ast.Name) or node.func.id != "log_phase":
            continue
        if len(node.args) < 2:
            continue
        tag, stage = node.args[:2]
        if isinstance(tag, ast.Constant) and isinstance(stage, ast.Constant):
            calls.append((node.lineno, tag.value, stage.value))
    return [(tag, stage) for _, tag, stage in sorted(calls)]


class WfstPhaseMarkerTests(unittest.TestCase):
    def test_sharded_mode_emits_coordinator_phases(self):
        calls = _direct_log_phase_calls("run_sharded_mode")
        self.assertEqual(
            calls,
            [
                ("DECODER_INIT", "START"),
                ("DECODER_INIT", "END"),
                ("DECODE", "START"),
                ("DECODE", "END"),
                ("SAVE", "START"),
                ("SAVE", "END"),
            ],
        )

    def test_single_process_decode_helper_still_emits_decode_phase(self):
        self.assertEqual(
            _direct_log_phase_calls("decode_selected_indices"),
            [("DECODE", "START"), ("DECODE", "END")],
        )
        self.assertEqual(
            _direct_log_phase_calls("run_single_process_mode"),
            [
                ("DECODER_INIT", "START"),
                ("DECODER_INIT", "END"),
                ("SAVE", "START"),
                ("SAVE", "END"),
            ],
        )

    def test_legacy_merge_phase_is_not_emitted(self):
        source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn("log_phase('MERGE'", source)
        self.assertNotIn('log_phase("MERGE"', source)


if __name__ == "__main__":
    unittest.main()
