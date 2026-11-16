"""Request validation, kept free of database imports so it is unit-testable anywhere."""


def validate(body: dict) -> tuple[str, int]:
    item, qty = body.get("item"), body.get("quantity", 1)
    if not isinstance(item, str) or not 1 <= len(item) <= 100:
        raise ValueError("item must be a string of 1-100 characters")
    if not isinstance(qty, int) or isinstance(qty, bool) or qty < 1:
        raise ValueError("quantity must be a positive integer")
    return item, qty
