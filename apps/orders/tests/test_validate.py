import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validation import validate  # noqa: E402


def test_valid_order():
    assert validate({"item": "tea", "quantity": 2}) == ("tea", 2)


def test_quantity_defaults_to_one():
    assert validate({"item": "tea"}) == ("tea", 1)


@pytest.mark.parametrize("body", [{}, {"item": ""}, {"item": "x" * 101}, {"item": "tea", "quantity": 0},
                                  {"item": "tea", "quantity": "2"}, {"item": "tea", "quantity": True}])
def test_invalid_orders(body):
    with pytest.raises(ValueError):
        validate(body)
