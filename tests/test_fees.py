import pytest

from exp.fees import ALL_IN, PLUS_FEES, Fee, load_fee_model, total_price


def test_all_in_is_unit_times_qty():
    assert total_price(Fee(ALL_IN), 54.26, 2) == 108.52


def test_plus_fees_applies_pct_then_fixed_per_ticket():
    fee = Fee(PLUS_FEES, pct=0.10, fixed_per_ticket=2.5)
    # (40 * 1.10 + 2.5) * 2 = 93.0
    assert total_price(fee, 40.0, 2) == 93.0


def test_default_model_keeps_marketplaces_all_in_and_vibepass_zero():
    model = load_fee_model(None)
    assert model["seatgeek"].basis == ALL_IN
    assert model["gotickets"].basis == ALL_IN
    assert total_price(model["vibepass"], 40.40, 2) == 80.8


def test_override_merges_over_defaults():
    model = load_fee_model('{"vibepass": {"basis": "plus_fees", "pct": 0.2}}')
    assert total_price(model["vibepass"], 100, 1) == 120.0
    assert model["seatgeek"].basis == ALL_IN


@pytest.mark.parametrize("bad", ["not json", "[]", '{"vibepass": 3}', '{"x": {"basis": "nope"}}'])
def test_bad_override_raises(bad):
    with pytest.raises(ValueError):
        load_fee_model(bad)


def test_negative_fee_rejected():
    with pytest.raises(ValueError):
        Fee(PLUS_FEES, pct=-0.1)


def test_zero_qty_rejected():
    with pytest.raises(ValueError):
        total_price(Fee(), 10, 0)
