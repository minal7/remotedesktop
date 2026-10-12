"""Source-only guard against benchmark fixture shortcuts in production code."""

from pathlib import Path
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PRODUCTION_DIRECTORY = (
    REPOSITORY_ROOT / "host-mac" / "RemoteDesktopHost" / "ComputerUse"
)
FORBIDDEN_FRAGMENTS = (
    "Value cable",
    "$7.00",
    "$12.50",
    "local fixture only",
    "replay-safe local checkout",
    "square-with-arrow icon",
    "Sort result list by price lowest first",
    "weekly groceries",
    "local express rate",
    "saved home address",
    "native input confirmed",
    "acceptance complete",
    "network action",
    "no order",
    "review delivery",
    "local only",
)
SCENARIO_LABEL = re.compile(r"B0[789]", re.IGNORECASE)
HEX_DIGEST = re.compile(r"\b[0-9a-f]{64}\b", re.IGNORECASE)


class ProductionFixtureIsolationTests(unittest.TestCase):
    def test_production_computer_use_sources_have_no_benchmark_shortcuts(self):
        self.assertTrue(
            PRODUCTION_DIRECTORY.is_dir(),
            f"Production ComputerUse source directory was not found: {PRODUCTION_DIRECTORY}",
        )
        production_files = sorted(
            path
            for path in PRODUCTION_DIRECTORY.rglob("*.swift")
            if path.is_file()
            and not any(
                component.startswith(".")
                for component in path.relative_to(PRODUCTION_DIRECTORY).parts
            )
        )
        self.assertTrue(
            production_files,
            f"No production ComputerUse Swift files found under {PRODUCTION_DIRECTORY}",
        )

        for source_path in production_files:
            source = source_path.read_text(encoding="utf-8")
            folded_source = source.casefold()
            for fragment in FORBIDDEN_FRAGMENTS:
                with self.subTest(file=source_path.name, forbidden_fragment=fragment):
                    self.assertNotIn(
                        fragment.casefold(),
                        folded_source,
                        f"Production ComputerUse source {source_path.name} "
                        f"contains benchmark fixture text: {fragment}",
                    )

            digest_spans = [match.span() for match in HEX_DIGEST.finditer(source)]
            for match in SCENARIO_LABEL.finditer(source):
                with self.subTest(file=source_path.name, scenario_label=match.group()):
                    self.assertTrue(
                        any(
                            start <= match.start() and match.end() <= end
                            for start, end in digest_spans
                        ),
                        f"Production ComputerUse source {source_path.name} "
                        "contains an acceptance scenario label",
                    )


if __name__ == "__main__":
    unittest.main()
