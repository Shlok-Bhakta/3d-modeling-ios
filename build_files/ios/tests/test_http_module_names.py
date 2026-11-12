# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

"""Catch names the port's HTTP download changes use without importing them.

These modules need Blender's bundled packages to import, so check them statically.
"""

import ast
import builtins
from pathlib import Path
import unittest


REPOSITORY = Path(__file__).resolve().parents[3]
HTTP = REPOSITORY / "scripts" / "modules" / "_bpy_internal" / "http"


def undefined_names(source: str) -> list[tuple[str, int]]:
    tree = ast.parse(source)
    bound = set(dir(builtins))
    for node in ast.walk(tree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            bound.update((alias.asname or alias.name).split(".")[0] for alias in node.names)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            bound.add(node.name)
        elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            bound.add(node.id)
        elif isinstance(node, ast.arg):
            bound.add(node.arg)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            bound.add(node.name)
    return [(node.id, node.lineno) for node in ast.walk(tree)
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id not in bound]


class HttpModuleNameTests(unittest.TestCase):
    def test_http_modules_import_every_name_they_use(self) -> None:
        for path in sorted(HTTP.glob("*.py")):
            with self.subTest(module=path.name):
                self.assertEqual(undefined_names(path.read_text()), [])


if __name__ == "__main__":
    unittest.main()
