# text-utils-sample

Tiny fixture for the coding-agent OTel kit. Run the tests with:

    python -m pytest -q

One existing test fails on purpose (an off-by-one in `truncate`), so an agent asked
to "make the test suite pass" has to read, run, edit and re-run.
