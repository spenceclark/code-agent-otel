from text_utils import normalize_whitespace, truncate


def test_normalize_whitespace_collapses_runs():
    assert normalize_whitespace("  hello \t\n  world  ") == "hello world"


def test_truncate_leaves_short_text_alone():
    assert truncate("short", 10) == "short"


def test_truncate_respects_limit_including_suffix():
    result = truncate("abcdefghijklmnop", 10)
    assert result == "abcdefg..."
    assert len(result) == 10
