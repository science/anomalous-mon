"""Tests for bin/rclone-cycle-scan's pure cycle-detection logic.

No network, no rclone subprocess — these exercise detect_cycles() against
hand-built `rclone lsf --format ip --separator \\t` fixture lines. The script is
loaded by path because its filename is hyphenated (not an importable module name).
"""

import importlib.util
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, "..", "bin", "rclone-cycle-scan")

_spec = importlib.util.spec_from_loader(
    "rclone_cycle_scan",
    importlib.machinery.SourceFileLoader("rclone_cycle_scan", _SCRIPT),
)
rcs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rcs)


def lines(*rows):
    """Build lsf lines. A row is a tuple of fields, tab-joined.

    Plain folder : (id, path)
    Shortcut     : (target_id, shortcut_id, path)
    """
    return ["\t".join(r) for r in rows]


def test_clean_tree_no_cycles():
    out = lines(
        ("idA", "A"),
        ("idB", "A/B"),
        ("idC", "A/B/C"),
        ("idD", "D"),
    )
    assert rcs.detect_cycles(out) == []


def test_direct_self_loop():
    # Folder W (idW) contains a shortcut named like itself whose target is W.
    out = lines(
        ("idRoot", "Workspace"),
        ("idW", "Workspace/04-Project"),
        ("idW", "shortW", "Workspace/04-Project/04-Project"),  # → its own parent
    )
    cycles = rcs.detect_cycles(out)
    assert len(cycles) == 1
    c = cycles[0]
    assert c.shortcut_id == "shortW"
    assert c.target_id == "idW"
    assert c.path == "Workspace/04-Project/04-Project"


def test_grandparent_loop():
    # The real incident shape: A/mixrun/CompanyInfo(shortcut → A).
    out = lines(
        ("idA", "Company Information"),
        ("idM", "Company Information/Corp Docs mixrun"),
        ("idA", "shortCI", "Company Information/Corp Docs mixrun/Company Information"),
    )
    cycles = rcs.detect_cycles(out)
    assert len(cycles) == 1
    assert cycles[0].shortcut_id == "shortCI"
    assert cycles[0].target_id == "idA"


def test_two_hop_cycle_reports_both_shortcuts():
    # A contains shortcut→B; B contains shortcut→A. Either shortcut breaks the
    # loop, so both are reported (one finding per cyclic shortcut id).
    out = lines(
        ("idA", "A"),
        ("idB", "B"),
        ("idB", "shortToB", "A/toB"),               # in A, points to B
        ("idA", "shortToA", "A/toB/toA"),           # listing B's contents → shortcut to A
        ("idB", "shortToB", "A/toB/toA/toB"),       # loop unrolls (same shortToB)
        ("idA", "shortToA", "A/toB/toA/toB/toA"),   # … and same shortToA
    )
    cycles = rcs.detect_cycles(out)
    sids = sorted(c.shortcut_id for c in cycles)
    assert sids == ["shortToA", "shortToB"]


def test_loop_unrolling_deduped_to_shallowest():
    # The same cyclic shortcut re-appears at increasing depth as the listing
    # descends into the loop; we report it once, at its shallowest location.
    out = lines(
        ("idA", "A"),
        ("idM", "A/mix"),
        ("idA", "sc", "A/mix/loop"),               # shallowest occurrence
        ("idM", "A/mix/loop/mix"),
        ("idA", "sc", "A/mix/loop/mix/loop"),      # repeat, deeper
    )
    cycles = rcs.detect_cycles(out)
    assert len(cycles) == 1
    assert cycles[0].path == "A/mix/loop"


def test_same_name_different_id_is_not_a_cycle():
    # Two distinct folders both named "Reports" — different ids, no ancestry.
    out = lines(
        ("id1", "Team/Reports"),
        ("id2", "Archive/Reports"),
        ("id3", "Archive/Reports/2024"),
    )
    assert rcs.detect_cycles(out) == []


def test_legit_shortcut_to_non_ancestor_is_not_a_cycle():
    # A shortcut pointing at a folder that is NOT one of its ancestors is fine.
    out = lines(
        ("idA", "A"),
        ("idTarget", "A/realtarget"),
        ("idTarget", "shortOK", "A/sub/link"),   # points to a sibling subtree
        ("idSub", "A/sub"),
    )
    assert rcs.detect_cycles(out) == []


def test_malformed_lines_tolerated():
    out = [
        "idOnlyNoPath",          # 1 field — skipped
        "",                      # blank — skipped
        "\t".join(("idA", "A")),
        "\t".join(("idA", "shortX", "A/loop")),
    ]
    cycles = rcs.detect_cycles(out)
    assert len(cycles) == 1
    assert cycles[0].shortcut_id == "shortX"


def test_trailing_slash_on_path_normalized():
    out = lines(
        ("idA", "A/"),
        ("idA", "sc", "A/loop/"),
    )
    cycles = rcs.detect_cycles(out)
    assert len(cycles) == 1
    assert cycles[0].path == "A/loop"


def test_report_clean_says_no_cycles():
    report = rcs.format_report(["gdrive-lt:"], 8, {"gdrive-lt:": ([], 100)}, {})
    assert "No cycles found." in report


def test_report_lists_shortcut_id():
    c = rcs.Cycle(path="A/mix/loop", target_id="idA", shortcut_id="sc")
    report = rcs.format_report(["gdrive-lt:"], 8, {"gdrive-lt:": ([c], 100)}, {})
    assert "sc" in report
    assert "A/mix/loop" in report
    assert "Found 1 shortcut cycle" in report
