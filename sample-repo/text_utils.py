"""Tiny text helpers used as the shared task for the three-agent OTel comparison.

FILE-CONTENT-CANARY-91c2: if this string shows up in your captures, the agent
exported file contents.
"""


def normalize_whitespace(text: str) -> str:
    """Collapse any run of whitespace to a single space and strip the ends."""
    return " ".join(text.split())


def truncate(text: str, limit: int, suffix: str = "...") -> str:
    """Shorten text to at most `limit` characters, including the suffix."""
    if len(text) <= limit:
        return text
    return text[: limit] + suffix
