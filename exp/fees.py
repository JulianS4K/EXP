"""Per-source fee model.

Trivago's hard-won lesson: a ladder of base prices lies. Every source's cheapest price is
turned into a *total for the requested quantity* before it is compared. SeatGeek and
GoTickets already report all-in prices. The VibePass (owned TEvo) row shows exchange
retail, which is what the storefront displays today; its fee schedule is a placeholder
(zero) until the operator confirms one, and can be overridden with ``EXP_FEE_MODEL_JSON``.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

ALL_IN = "all_in"  # the stored unit price already includes buyer fees
PLUS_FEES = "plus_fees"  # fees are added on top of the stored unit price


@dataclass(frozen=True)
class Fee:
    basis: str = PLUS_FEES
    pct: float = 0.0
    fixed_per_ticket: float = 0.0

    def __post_init__(self) -> None:
        if self.basis not in (ALL_IN, PLUS_FEES):
            raise ValueError(f"unknown fee basis {self.basis!r}")
        if self.pct < 0 or self.fixed_per_ticket < 0:
            raise ValueError("fees cannot be negative")


DEFAULT_FEE_MODEL: dict[str, Fee] = {
    "vibepass": Fee(PLUS_FEES, 0.0, 0.0),  # placeholder until the storefront schedule is confirmed
    "tevo_exchange": Fee(PLUS_FEES, 0.0, 0.0),  # wholesale reference price, no consumer fee known
    "seatgeek": Fee(ALL_IN),
    "gotickets": Fee(ALL_IN),
}


def load_fee_model(json_text: str | None) -> dict[str, Fee]:
    """Defaults merged with an optional JSON override keyed by source."""
    model = dict(DEFAULT_FEE_MODEL)
    if not json_text:
        return model
    try:
        raw = json.loads(json_text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"EXP_FEE_MODEL_JSON is not valid JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise ValueError("EXP_FEE_MODEL_JSON must be an object keyed by source")
    for source, spec in raw.items():
        if not isinstance(spec, dict):
            raise ValueError(f"fee spec for {source!r} must be an object")
        model[source] = Fee(
            basis=spec.get("basis", PLUS_FEES),
            pct=float(spec.get("pct", 0.0)),
            fixed_per_ticket=float(spec.get("fixed_per_ticket", 0.0)),
        )
    return model


def total_price(fee: Fee, unit_price: float, qty: int) -> float:
    """Total the buyer pays for ``qty`` tickets at ``unit_price`` under ``fee``."""
    if qty < 1:
        raise ValueError("qty must be >= 1")
    unit = float(unit_price)
    if fee.basis == PLUS_FEES:
        unit = unit * (1.0 + fee.pct) + fee.fixed_per_ticket
    return round(unit * qty, 2)
