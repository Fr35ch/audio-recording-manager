#!/usr/bin/env python3
"""Bridge script: anonymize Norwegian text using no-anonymizer.

Called by AnonymizationService.swift via subprocess.
Reads input text from --input file, writes JSON result to --output file.

Exit codes:
    0  success
    1  unexpected error
    3  no-anonymizer not installed
"""

import argparse
import json
import os
import sys
import traceback


def main() -> None:
    parser = argparse.ArgumentParser(description="no-anonymizer bridge")
    parser.add_argument("--input", required=True, help="Path to input text file")
    parser.add_argument("--output", required=True, help="Path to write JSON result")
    args = parser.parse_args()

    try:
        with open(args.input, encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        _write_error({"error": "io_error", "message": str(exc)})
        sys.exit(1)

    try:
        from no_anonymizer import anonymize
    except ImportError:
        # Fallback: try to locate the no-anonymizer src/ in common development paths
        _added = False
        for candidate in [
            os.path.expanduser("~/Github/no-anonymizer/src"),
        ]:
            if os.path.isdir(candidate) and candidate not in sys.path:
                sys.path.insert(0, candidate)
                _added = True
                break
        if _added:
            try:
                from no_anonymizer import anonymize
            except ImportError:
                _write_error(
                    {
                        "error": "library_not_installed",
                        "message": (
                            "no-anonymizer er ikke installert. Installer via: "
                            "pip install 'no-anonymizer[ner]'"
                        ),
                    }
                )
                sys.exit(3)
        else:
            _write_error(
                {
                    "error": "library_not_installed",
                    "message": (
                        "no-anonymizer er ikke installert. Installer via: "
                        "pip install 'no-anonymizer[ner]'"
                    ),
                }
            )
            sys.exit(3)

    try:
        result = anonymize(text)
    except RuntimeError as exc:
        _write_error({"error": "runtime_error", "message": str(exc)})
        sys.exit(1)
    except Exception as exc:
        _write_error(
            {
                "error": "unexpected",
                "message": traceback.format_exc(),
            }
        )
        sys.exit(1)

    payload = {
        "anonymizedText": result.anonymized_text,
        "redactions": [
            {
                "position": r.original_position,
                "length": r.length,
                "category": r.category,
                "replacement": r.replacement,
            }
            for r in result.redactions
        ],
        "stats": result.stats,
        "processingTimeMs": result.processing_time_ms,
    }

    try:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
    except OSError as exc:
        _write_error({"error": "io_error", "message": str(exc)})
        sys.exit(1)

    sys.exit(0)


def _write_error(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), file=sys.stderr)


if __name__ == "__main__":
    main()
