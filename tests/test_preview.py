"""Theme projection uses complete, consistent files without desktop changes."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import preview


class ThemeProjectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="daylog-theme-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.theme = self.root / "themes/catppuccin"
        self.theme.mkdir(parents=True)
        self.colors = 'background = "#112233"\nforeground = "#ddeeff"\naccent = "#8899aa"\nred = "#cc3344"\n'
        (self.theme / "colors.toml").write_text(self.colors)
        (self.theme / "shell.toml").write_text('[font]\nbase-size = 12\n')
        patcher = patch.object(preview, "OMARCHY", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_named_theme_uses_stock_fallback_without_current_inputs(self):
        (self.theme / "shell.toml").unlink()
        template = self.root / "default/themed/shell.toml.tpl"
        template.parent.mkdir(parents=True)
        template.write_text('[popups]\nbackground = "{{ background }}"\n')
        with patch.object(Path, "home", side_effect=AssertionError("Named themes must not read current theme inputs")):
            result = preview.theme_snapshot("catppuccin")
        self.assertEqual(result["background"], "#ff112233")
        self.assertEqual(result["radius"], 0)

    def test_empty_malformed_and_valid_shell(self):
        shell = self.theme / "shell.toml"
        for text in ("", '[font]\nbase-size = "unfinished'):
            shell.write_text(text)
            with self.assertRaises(ValueError):
                preview.theme_snapshot("catppuccin")
        shell.write_text('[font]\nbase-size = 18\n')
        self.assertEqual(preview.theme_snapshot("catppuccin")["font"]["body"], 18)

    def test_incomplete_palette_is_rejected_then_recovers(self):
        colors = self.theme / "colors.toml"
        colors.write_text('background = "#112233"\n')
        with self.assertRaises(ValueError):
            preview.theme_snapshot("catppuccin")
        colors.write_text(self.colors)
        self.assertEqual(preview.theme_snapshot("catppuccin")["accent"], "#ff8899aa")

    def test_atomic_replacement_during_projection_is_rejected(self):
        load = preview.load_toml
        colors = self.theme / "colors.toml"

        def replace_after_read(path):
            result = load(path)
            if path == colors:
                replacement = self.theme / "replacement.toml"
                replacement.write_text(self.colors.replace("#112233", "#223344"))
                replacement.replace(colors)
            return result

        with patch.object(preview, "load_toml", side_effect=replace_after_read):
            with self.assertRaisesRegex(ValueError, "changed while reading"):
                preview.theme_snapshot("catppuccin")
        self.assertEqual(preview.theme_snapshot("catppuccin")["background"], "#ff223344")

    def test_current_missing_shell_does_not_publish_template_during_swap(self):
        current = self.root / ".local/state/omarchy/current/theme"
        current.mkdir(parents=True)
        (current / "colors.toml").write_text(self.colors)
        with patch.object(Path, "home", return_value=self.root):
            with self.assertRaises(FileNotFoundError):
                preview.theme_snapshot("current")


if __name__ == "__main__":
    unittest.main()
